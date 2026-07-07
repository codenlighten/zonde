//! zonde — a tiny observability agent.
//!
//! Reads Linux /proc and exposes Prometheus metrics. Modes:
//!   zonde                     serve /metrics over HTTP (default, port 9100)
//!   zonde --once              print one scrape to stdout and exit
//!   zonde --listen ADDR       bind address (default 0.0.0.0)
//!   zonde --port N            listen on port N
//!   zonde --otlp URL          push OTLP/JSON to URL on an interval (agent mode)
//!   zonde --otlp URL --interval S   set push interval seconds (default 60)
//!
//! Config precedence is flags > ZONDE_* env vars > defaults (see config.zig).
//! Uses the 0.16 `std.Io` interface — `io`/`gpa`/`environ` arrive via "juicy
//! main" (`std.process.Init`), threaded explicitly rather than reached globally.

const std = @import("std");
const collectors = @import("collectors.zig");
const server = @import("server.zig");
const exporter = @import("exporter.zig");
const config = @import("config.zig");
const PromSink = @import("sink_prom.zig").PromSink;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // defaults <- environment <- CLI flags
    var cfg = config.fromEnv(init.environ_map);

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.skip(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--once")) {
            cfg.mode = .once;
        } else if (std.mem.eql(u8, arg, "--listen")) {
            cfg.listen_addr = args.next() orelse fatal(io, "--listen requires an address", .{});
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            cfg.listen_addr = arg["--listen=".len..];
        } else if (std.mem.eql(u8, arg, "--port")) {
            cfg.port = try parseNext(io, &args, u16, "--port");
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            cfg.port = parseArg(io, u16, arg["--port=".len..]);
        } else if (std.mem.eql(u8, arg, "--otlp")) {
            cfg.otlp_endpoint = args.next() orelse fatal(io, "--otlp requires a URL", .{});
            cfg.mode = .push;
        } else if (std.mem.startsWith(u8, arg, "--otlp=")) {
            cfg.otlp_endpoint = arg["--otlp=".len..];
            cfg.mode = .push;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            cfg.interval_s = try parseNext(io, &args, u64, "--interval");
        } else if (std.mem.startsWith(u8, arg, "--interval=")) {
            cfg.interval_s = parseArg(io, u64, arg["--interval=".len..]);
        } else if (std.mem.eql(u8, arg, "--path.procfs")) {
            cfg.procfs_path = args.next() orelse fatal(io, "--path.procfs requires a path", .{});
        } else if (std.mem.startsWith(u8, arg, "--path.procfs=")) {
            cfg.procfs_path = arg["--path.procfs=".len..];
        } else if (std.mem.eql(u8, arg, "--path.rootfs")) {
            cfg.rootfs_path = args.next() orelse fatal(io, "--path.rootfs requires a path", .{});
        } else if (std.mem.startsWith(u8, arg, "--path.rootfs=")) {
            cfg.rootfs_path = arg["--path.rootfs=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try usage(io);
            return;
        } else {
            fatal(io, "unknown argument: {s}", .{arg});
        }
    }

    const ctx: collectors.Context = .{
        .io = io,
        .gpa = gpa,
        .procfs = cfg.procfs_path,
        .rootfs = cfg.rootfs_path,
    };

    switch (cfg.mode) {
        .once => try printScrape(ctx),
        .serve => try server.serve(ctx, cfg.listen_addr, cfg.port),
        .push => try exporter.run(ctx, cfg.otlp_endpoint.?, cfg.interval_s),
    }
}

fn printScrape(ctx: collectors.Context) !void {
    var buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(ctx.io, &buf);
    var prom = PromSink{ .w = &stdout.interface };
    try collectors.scrape(ctx, prom.sink());
    try stdout.interface.flush(); // 0.16 writers buffer — without flush, output is lost.
}

fn parseNext(io: std.Io, args: anytype, comptime T: type, flag: []const u8) !T {
    const val = args.next() orelse fatal(io, "{s} requires a value", .{flag});
    return parseArg(io, T, val);
}

fn parseArg(io: std.Io, comptime T: type, val: []const u8) T {
    return std.fmt.parseInt(T, val, 10) catch fatal(io, "invalid value: {s}", .{val});
}

fn usage(io: std.Io) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.writeAll(
        \\zonde — tiny observability agent
        \\
        \\usage:
        \\  zonde                     serve /metrics over HTTP (default, port 9100)
        \\  zonde --once              print one scrape to stdout and exit
        \\  zonde --listen ADDR       bind address (default 0.0.0.0)
        \\  zonde --port N            listen on port N
        \\  zonde --otlp URL          push OTLP/JSON to URL on an interval
        \\  zonde --otlp URL --interval S   push every S seconds (default 60)
        \\  zonde --path.procfs PATH  where /proc is mounted (default /proc)
        \\  zonde --path.rootfs PATH  prefix for filesystem mountpoints (container host mon.)
        \\  zonde --help              show this help
        \\
        \\env: ZONDE_LISTEN_ADDR, ZONDE_PORT, ZONDE_OTLP_ENDPOINT, ZONDE_INTERVAL,
        \\     ZONDE_PATH_PROCFS, ZONDE_PATH_ROOTFS
        \\     (flags override env; env overrides defaults)
        \\
    );
    try stdout.interface.flush();
}

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    stderr.interface.print("zonde: error: " ++ fmt ++ "\n", args) catch {};
    stderr.interface.flush() catch {};
    std.process.exit(2);
}

test {
    // Pull collector and sink tests into `zig build test`.
    _ = collectors;
    _ = @import("sink_otlp.zig");
}
