//! M3: OTLP/HTTP push exporter.
//!
//! On an interval: scrape → serialize OTLP/JSON → POST to the collector's
//! `/v1/metrics` endpoint via `std.http.Client`. Push failures are logged and
//! retried on the next tick rather than being fatal — an agent must outlive a
//! temporarily-unreachable collector.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const collectors = @import("collectors.zig");
const OtlpSink = @import("sink_otlp.zig").OtlpSink;

pub fn run(io: Io, gpa: Allocator, endpoint: []const u8, interval_s: u64) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    logInfo(io, "OTLP push -> {s} every {d}s", .{ endpoint, interval_s });
    while (true) {
        pushOnce(io, gpa, &client, endpoint) catch |err| {
            logInfo(io, "push failed: {s}", .{@errorName(err)});
        };
        // Monotonic clock so wall-clock jumps (NTP) don't skew the interval.
        std.Io.sleep(io, .fromSeconds(@intCast(interval_s)), .awake) catch return;
    }
}

fn pushOnce(io: Io, gpa: Allocator, client: *std.http.Client, endpoint: []const u8) !void {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
    var otlp = OtlpSink.init(&body.writer, ts, "zonde");
    try collectors.scrape(io, gpa, otlp.sink());
    try otlp.finish();

    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body.written(),
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
    logInfo(io, "pushed {d} bytes -> HTTP {d}", .{ body.written().len, @intFromEnum(result.status) });
}

fn logInfo(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("zonde: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}
