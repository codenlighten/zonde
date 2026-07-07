//! Runtime configuration with precedence: CLI flags > environment > defaults.
//!
//! `fromEnv` builds the env-overlaid defaults; `main` then applies flag
//! overrides on top. Keeping the shape here (rather than scattered constants)
//! makes the agent configurable for containers/systemd without code changes.

const std = @import("std");
const Environ = std.process.Environ;

pub const Mode = enum { serve, once, push };

pub const Config = struct {
    mode: Mode = .serve,
    listen_addr: []const u8 = "0.0.0.0",
    port: u16 = 9100,
    otlp_endpoint: ?[]const u8 = null,
    interval_s: u64 = 60,
    // Base paths for host monitoring from a container (node_exporter-style).
    procfs_path: []const u8 = "/proc",
    rootfs_path: []const u8 = "",
    sysfs_path: []const u8 = "/sys",
};

/// Defaults overlaid with `ZONDE_*` environment variables. Malformed numeric
/// values are ignored (defaults retained) rather than aborting startup.
pub fn fromEnv(env: *const Environ.Map) Config {
    var c: Config = .{};
    if (env.get("ZONDE_LISTEN_ADDR")) |v| c.listen_addr = v;
    if (env.get("ZONDE_PORT")) |v| {
        if (std.fmt.parseInt(u16, v, 10) catch null) |p| c.port = p;
    }
    if (env.get("ZONDE_INTERVAL")) |v| {
        if (std.fmt.parseInt(u64, v, 10) catch null) |n| c.interval_s = n;
    }
    if (env.get("ZONDE_OTLP_ENDPOINT")) |v| {
        c.otlp_endpoint = v;
        c.mode = .push; // presence of an endpoint selects agent mode
    }
    if (env.get("ZONDE_PATH_PROCFS")) |v| c.procfs_path = v;
    if (env.get("ZONDE_PATH_ROOTFS")) |v| c.rootfs_path = v;
    if (env.get("ZONDE_PATH_SYSFS")) |v| c.sysfs_path = v;
    return c;
}
