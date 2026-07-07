//! M1: serve the scrape over HTTP so Prometheus can pull it.
//!
//! Built on the 0.16 `std.Io` networking + `std.http.Server` stack. The HTTP
//! server is transport-agnostic (`init(*Reader, *Writer)`), so we hand it the
//! reader/writer of an accepted TCP `Stream`. One blocking accept loop for now;
//! M-later can fan connections out with `io.async` once we want concurrency.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const collectors = @import("collectors.zig");
const PromSink = @import("sink_prom.zig").PromSink;

/// Prometheus text exposition content-type (format version 0.0.4).
const exposition_content_type = "text/plain; version=0.0.4; charset=utf-8";

pub fn serve(ctx: collectors.Context, listen_addr: []const u8, port: u16) !void {
    const io = ctx.io;
    var address = try net.IpAddress.parse(listen_addr, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    logInfo(io, "serving /metrics on http://{s}:{d}/metrics", .{ listen_addr, port });

    while (true) {
        const stream = server.accept(io) catch |err| {
            logInfo(io, "accept failed: {s}", .{@errorName(err)});
            continue;
        };
        // Handle inline for now: one connection at a time. Errors here are
        // per-connection (client hung up, malformed request) and must not kill
        // the server, so we swallow them.
        handleConnection(ctx, stream) catch {};
    }
}

fn handleConnection(ctx: collectors.Context, stream: net.Stream) !void {
    const io = ctx.io;
    defer stream.close(io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [64 * 1024]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buf);
    var conn_writer = stream.writer(io, &send_buf);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    // Serve requests until the client closes or asks to (keep-alive).
    while (true) {
        var request = http_server.receiveHead() catch return;
        try route(ctx, &request);
        if (!request.head.keep_alive) return;
    }
}

fn route(ctx: collectors.Context, request: *std.http.Server.Request) !void {
    // Path without the query string.
    const target = request.head.target;
    const path = target[0..(std.mem.indexOfScalar(u8, target, '?') orelse target.len)];

    const method = request.head.method;
    if (method != .GET and method != .HEAD) {
        // keep_alive=false: we won't read a request body, so close rather than
        // let respond() try to discard one (which asserts on unframed bodies).
        try request.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .keep_alive = false,
        });
        return;
    }

    if (std.mem.eql(u8, path, "/metrics")) {
        try respondMetrics(ctx, request);
    } else if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/health")) {
        try request.respond("zonde ok\n", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
    } else {
        try request.respond("not found\n", .{ .status = .not_found });
    }
}

fn respondMetrics(ctx: collectors.Context, request: *std.http.Server.Request) !void {
    // Render the whole exposition into a buffer, then send it with a
    // content-length. Streaming the body directly is a later optimization.
    var body: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer body.deinit();

    var prom = PromSink{ .w = &body.writer };
    collectors.scrape(ctx, prom.sink()) catch {
        try request.respond("scrape failed\n", .{ .status = .internal_server_error });
        return;
    };

    try request.respond(body.written(), .{
        .extra_headers = &.{.{ .name = "content-type", .value = exposition_content_type }},
    });
}

fn logInfo(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("zonde: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}
