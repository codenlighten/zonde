//! Linux `/proc` collectors. Each reads a file under the configured procfs base
//! with the `Context`'s `Io`, parses it, and emits samples into a `metric.Sink`
//! — which renders them as Prometheus text or OTLP/JSON. No globals, no hidden I/O.
//!
//! Collectors are registered in `registry`; `scrape` runs them all and turns any
//! single failure into a `zonde_collector_error` sample rather than aborting.
//! Each collector emits its metric families one at a time (all samples of a
//! family consecutively), which is the contract sinks rely on for grouping.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const metric = @import("metric.zig");
const Sink = metric.Sink;
const Metric = metric.Metric;
const Label = metric.Label;

/// USER_HZ: kernel CPU counters in /proc/stat are expressed in clock ticks.
/// 100 is correct on effectively all mainstream Linux configs; a later milestone
/// will read this from sysconf(_SC_CLK_TCK) instead of assuming.
const user_hz: f64 = 100.0;

/// Sectors in /proc/diskstats are always 512 bytes regardless of device geometry.
const sector_bytes: u64 = 512;

/// Upper bound on per-device rows we parse in one scrape (network interfaces,
/// block devices). Keeps collectors allocation-free; overflow just truncates.
const max_rows = 256;

/// Everything a collector needs. The base paths make host monitoring from
/// inside a container possible, mirroring node_exporter's `--path.*` flags:
///   * `procfs` — where /proc is mounted (default "/proc"; e.g. "/host/proc").
///   * `rootfs` — prepended to filesystem mountpoints before statfs (default ""
///     = statfs paths as-is; e.g. "/host/root" when the host root is bind-mounted).
pub const Context = struct {
    io: Io,
    gpa: Allocator,
    procfs: []const u8 = "/proc",
    rootfs: []const u8 = "",
    sysfs: []const u8 = "/sys",
};

const CollectFn = *const fn (Context, Sink) anyerror!void;

pub const Collector = struct {
    name: []const u8,
    collect: CollectFn,
};

pub const registry = [_]Collector{
    .{ .name = "memory", .collect = collectMemory },
    .{ .name = "cpu", .collect = collectCpu },
    .{ .name = "loadavg", .collect = collectLoad },
    .{ .name = "netdev", .collect = collectNetdev },
    .{ .name = "diskstats", .collect = collectDiskstats },
    .{ .name = "pressure", .collect = collectPressure },
    .{ .name = "filesystem", .collect = collectFilesystem },
    .{ .name = "filefd", .collect = collectFilefd },
    .{ .name = "entropy", .collect = collectEntropy },
    .{ .name = "stat", .collect = collectStat },
    .{ .name = "uname", .collect = collectUname },
    .{ .name = "sockstat", .collect = collectSockstat },
    .{ .name = "netstat", .collect = collectNetstat },
    .{ .name = "thermal", .collect = collectThermal },
};

/// Run every collector once, emitting a full set of samples into `sink`.
/// A single collector failing (e.g. a /proc file missing in a container) must
/// not abort the whole scrape — its failure is surfaced as a sample instead.
pub fn scrape(ctx: Context, sink: Sink) anyerror!void {
    try sink.emit(.{ .name = "zonde_up", .help = "Whether the zonde scrape succeeded.", .kind = .gauge }, &.{}, .{ .int = 1 });

    inline for (registry) |c| {
        c.collect(ctx, sink) catch |err| try emitCollectorError(sink, c.name, err);
    }
}

// --- shared helpers ---------------------------------------------------------

/// Read a whole virtual file under `base` (e.g. `base=<procfs>, sub="meminfo"`).
/// We must stream to EOF rather than use `readFileAlloc`: /proc and /sys files
/// report `st_size == 0`, so any size-hinted read returns empty.
fn readVirtual(ctx: Context, base: []const u8, sub: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, sub });
    var file = try std.Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(ctx.io, &read_buf);
    return reader.interface.allocRemaining(ctx.gpa, .limited(1 << 20));
}

fn readProc(ctx: Context, sub: []const u8) ![]u8 {
    return readVirtual(ctx, ctx.procfs, sub);
}

fn readSys(ctx: Context, sub: []const u8) ![]u8 {
    return readVirtual(ctx, ctx.sysfs, sub);
}

fn emitCollectorError(sink: Sink, collector: []const u8, err: anyerror) anyerror!void {
    try sink.emit(
        .{ .name = "zonde_collector_error", .help = "A collector failed during scrape.", .kind = .gauge },
        &.{ .{ .name = "collector", .value = collector }, .{ .name = "error", .value = @errorName(err) } },
        .{ .int = 1 },
    );
}

// --- memory -----------------------------------------------------------------

const MemMetric = struct { key: []const u8, name: []const u8, help: []const u8 };
const mem_metrics = [_]MemMetric{
    .{ .key = "MemTotal", .name = "node_memory_MemTotal_bytes", .help = "Total usable RAM." },
    .{ .key = "MemFree", .name = "node_memory_MemFree_bytes", .help = "Free RAM." },
    .{ .key = "MemAvailable", .name = "node_memory_MemAvailable_bytes", .help = "Estimated available RAM." },
    .{ .key = "Buffers", .name = "node_memory_Buffers_bytes", .help = "Memory in buffers." },
    .{ .key = "Cached", .name = "node_memory_Cached_bytes", .help = "Memory in the page cache." },
};

fn collectMemory(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "meminfo");
    defer ctx.gpa.free(data);

    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const parsed = parseMeminfoLine(line) orelse continue;
        for (mem_metrics) |m| {
            if (std.mem.eql(u8, parsed.key, m.key)) {
                // /proc/meminfo values are in kB; Prometheus convention is bytes.
                try sink.emit(.{ .name = m.name, .help = m.help, .kind = .gauge }, &.{}, .{ .int = parsed.kb * 1024 });
            }
        }
    }
}

const MeminfoLine = struct { key: []const u8, kb: u64 };

/// Parse one `/proc/meminfo` line: `"MemTotal:      16384 kB"` -> key + kB value.
/// Pure and total (returns null on anything unexpected) so it is unit-testable.
fn parseMeminfoLine(line: []const u8) ?MeminfoLine {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = line[0..colon];
    var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const num = fields.next() orelse return null;
    const kb = std.fmt.parseInt(u64, num, 10) catch return null;
    return .{ .key = key, .kb = kb };
}

// --- cpu ---------------------------------------------------------------------

const cpu_modes = [_][]const u8{
    "user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal",
};

fn collectCpu(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "stat");
    defer ctx.gpa.free(data);

    const m: Metric = .{ .name = "node_cpu_seconds_total", .help = "Seconds each CPU spent in each mode.", .kind = .counter };
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        // Per-core lines ("cpu0", "cpu1", ...) come first; stop once they end.
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const label = fields.next() orelse continue;
        const cpu_id = label[3..]; // "" for the aggregate "cpu" line
        if (cpu_id.len == 0) continue; // skip aggregate; expose per-core only

        var i: usize = 0;
        while (fields.next()) |val| : (i += 1) {
            if (i >= cpu_modes.len) break;
            const ticks = std.fmt.parseInt(u64, val, 10) catch continue;
            const secs = @as(f64, @floatFromInt(ticks)) / user_hz;
            try sink.emit(m, &.{ .{ .name = "cpu", .value = cpu_id }, .{ .name = "mode", .value = cpu_modes[i] } }, .{ .float = secs });
        }
    }
}

// --- loadavg -----------------------------------------------------------------

fn collectLoad(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "loadavg");
    defer ctx.gpa.free(data);

    var fields = std.mem.tokenizeAny(u8, data, " \t\n");
    const names = [_][]const u8{ "node_load1", "node_load5", "node_load15" };
    const helps = [_][]const u8{ "1m load average.", "5m load average.", "15m load average." };
    inline for (names, helps) |name, help| {
        const field = fields.next() orelse return error.MalformedLoadavg;
        const value = std.fmt.parseFloat(f64, field) catch return error.MalformedLoadavg;
        try sink.emit(.{ .name = name, .help = help, .kind = .gauge }, &.{}, .{ .float = value });
    }
}

// --- netdev ------------------------------------------------------------------

const NetDev = struct {
    rx_bytes: u64,
    rx_packets: u64,
    rx_errs: u64,
    rx_drop: u64,
    tx_bytes: u64,
    tx_packets: u64,
    tx_errs: u64,
    tx_drop: u64,
};
const NetEntry = struct { iface: []const u8, s: NetDev };

/// One `/proc/net/dev` data line: `"  eth0: <8 rx fields> <8 tx fields>"`.
fn parseNetdevLine(line: []const u8) ?NetEntry {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const iface = std.mem.trim(u8, line[0..colon], " \t");
    if (iface.len == 0) return null;

    var v: [16]u64 = undefined;
    var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    var n: usize = 0;
    while (fields.next()) |tok| : (n += 1) {
        if (n >= v.len) break;
        v[n] = std.fmt.parseInt(u64, tok, 10) catch return null;
    }
    if (n < v.len) return null;

    // rx: bytes packets errs drop fifo frame compressed multicast (v[0..8])
    // tx: bytes packets errs drop fifo colls carrier compressed  (v[8..16])
    return .{ .iface = iface, .s = .{
        .rx_bytes = v[0],
        .rx_packets = v[1],
        .rx_errs = v[2],
        .rx_drop = v[3],
        .tx_bytes = v[8],
        .tx_packets = v[9],
        .tx_errs = v[10],
        .tx_drop = v[11],
    } };
}

fn collectNetdev(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "net/dev");
    defer ctx.gpa.free(data);

    var rows: [max_rows]NetEntry = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    _ = lines.next(); // "Inter-|   Receive ..."
    _ = lines.next(); // " face |bytes packets ..."
    while (lines.next()) |line| {
        const e = parseNetdevLine(line) orelse continue;
        if (count >= rows.len) break;
        rows[count] = e;
        count += 1;
    }
    const list = rows[0..count];

    const Family = struct { name: []const u8, help: []const u8, field: std.meta.FieldEnum(NetDev) };
    const families = [_]Family{
        .{ .name = "node_network_receive_bytes_total", .help = "Bytes received.", .field = .rx_bytes },
        .{ .name = "node_network_receive_packets_total", .help = "Packets received.", .field = .rx_packets },
        .{ .name = "node_network_receive_errs_total", .help = "Receive errors.", .field = .rx_errs },
        .{ .name = "node_network_receive_drop_total", .help = "Receive drops.", .field = .rx_drop },
        .{ .name = "node_network_transmit_bytes_total", .help = "Bytes transmitted.", .field = .tx_bytes },
        .{ .name = "node_network_transmit_packets_total", .help = "Packets transmitted.", .field = .tx_packets },
        .{ .name = "node_network_transmit_errs_total", .help = "Transmit errors.", .field = .tx_errs },
        .{ .name = "node_network_transmit_drop_total", .help = "Transmit drops.", .field = .tx_drop },
    };
    inline for (families) |f| {
        const m: Metric = .{ .name = f.name, .help = f.help, .kind = .counter };
        for (list) |e| {
            try sink.emit(m, &.{.{ .name = "device", .value = e.iface }}, .{ .int = @field(e.s, @tagName(f.field)) });
        }
    }
}

// --- diskstats ---------------------------------------------------------------

const DiskStat = struct {
    reads: u64,
    read_sectors: u64,
    writes: u64,
    written_sectors: u64,
    io_ms: u64,
};
const DiskEntry = struct { name: []const u8, s: DiskStat };

/// One `/proc/diskstats` line. Fields after the device name (1-indexed in the
/// kernel docs): 1 reads, 3 sectors read, 5 writes, 7 sectors written, 10 ms in I/O.
fn parseDiskstatsLine(line: []const u8) ?DiskEntry {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    _ = fields.next() orelse return null; // major
    _ = fields.next() orelse return null; // minor
    const name = fields.next() orelse return null;

    var v: [11]u64 = undefined;
    var n: usize = 0;
    while (fields.next()) |tok| : (n += 1) {
        if (n >= v.len) break;
        v[n] = std.fmt.parseInt(u64, tok, 10) catch return null;
    }
    if (n < 10) return null; // need through v[9] = ms doing I/O

    return .{ .name = name, .s = .{
        .reads = v[0],
        .read_sectors = v[2],
        .writes = v[4],
        .written_sectors = v[6],
        .io_ms = v[9],
    } };
}

/// Skip virtual/noise block devices the way node_exporter does by default.
fn isNoiseDisk(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "loop") or std.mem.startsWith(u8, name, "ram");
}

fn collectDiskstats(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "diskstats");
    defer ctx.gpa.free(data);

    var rows: [max_rows]DiskEntry = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const e = parseDiskstatsLine(line) orelse continue;
        if (isNoiseDisk(e.name)) continue;
        if (count >= rows.len) break;
        rows[count] = e;
        count += 1;
    }
    const list = rows[0..count];

    try emitDisk(sink, list, "node_disk_reads_completed_total", "Reads completed.", .reads, 1);
    try emitDisk(sink, list, "node_disk_read_bytes_total", "Bytes read.", .read_sectors, sector_bytes);
    try emitDisk(sink, list, "node_disk_writes_completed_total", "Writes completed.", .writes, 1);
    try emitDisk(sink, list, "node_disk_written_bytes_total", "Bytes written.", .written_sectors, sector_bytes);

    const io_time: Metric = .{ .name = "node_disk_io_time_seconds_total", .help = "Seconds spent doing I/O.", .kind = .counter };
    for (list) |e| {
        try sink.emit(io_time, &.{.{ .name = "device", .value = e.name }}, .{ .float = @as(f64, @floatFromInt(e.s.io_ms)) / 1000.0 });
    }
}

fn emitDisk(sink: Sink, list: []const DiskEntry, name: []const u8, help: []const u8, comptime field: std.meta.FieldEnum(DiskStat), scale: u64) anyerror!void {
    const m: Metric = .{ .name = name, .help = help, .kind = .counter };
    for (list) |e| {
        try sink.emit(m, &.{.{ .name = "device", .value = e.name }}, .{ .int = @field(e.s, @tagName(field)) * scale });
    }
}

// --- pressure (PSI) ----------------------------------------------------------

const PressureMetric = struct {
    file: []const u8,
    line_prefix: []const u8, // "some" or "full"
    name: []const u8,
    help: []const u8,
};
const pressure_metrics = [_]PressureMetric{
    .{ .file = "pressure/cpu", .line_prefix = "some", .name = "node_pressure_cpu_waiting_seconds_total", .help = "Total seconds tasks waited on CPU." },
    .{ .file = "pressure/memory", .line_prefix = "some", .name = "node_pressure_memory_waiting_seconds_total", .help = "Total seconds tasks waited on memory." },
    .{ .file = "pressure/memory", .line_prefix = "full", .name = "node_pressure_memory_stalled_seconds_total", .help = "Total seconds all tasks stalled on memory." },
    .{ .file = "pressure/io", .line_prefix = "some", .name = "node_pressure_io_waiting_seconds_total", .help = "Total seconds tasks waited on I/O." },
    .{ .file = "pressure/io", .line_prefix = "full", .name = "node_pressure_io_stalled_seconds_total", .help = "Total seconds all tasks stalled on I/O." },
};

fn collectPressure(ctx: Context, sink: Sink) anyerror!void {
    // PSI may be absent (older kernels or CONFIG_PSI=n); reading any file then
    // fails and the whole collector is reported once via zonde_collector_error.
    inline for (pressure_metrics) |m| {
        const data = try readProc(ctx, m.file);
        defer ctx.gpa.free(data);
        const total_us = psiTotal(data, m.line_prefix) orelse return error.MalformedPressure;
        // PSI "total" is accumulated microseconds; Prometheus convention is seconds.
        try sink.emit(.{ .name = m.name, .help = m.help, .kind = .counter }, &.{}, .{ .float = @as(f64, @floatFromInt(total_us)) / 1_000_000.0 });
    }
}

/// From a PSI file, find the line beginning with `prefix` ("some"/"full") and
/// return its `total=` value (microseconds).
fn psiTotal(data: []const u8, prefix: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const key = "total=";
        const idx = std.mem.indexOf(u8, line, key) orelse return null;
        var toks = std.mem.tokenizeAny(u8, line[idx + key.len ..], " \t");
        const tok = toks.next() orelse return null;
        return std.fmt.parseInt(u64, tok, 10) catch null;
    }
    return null;
}

// --- filesystem --------------------------------------------------------------

const linux = std.os.linux;

/// Linux 64-bit `struct statfs`. The kernel writes the whole struct, so the
/// layout must be complete even though we only read a few fields. Identical on
/// x86_64 and aarch64 (all `__SWORD_TYPE` are 64-bit); this collector is
/// Linux-64-bit only, which matches every zonde release target.
const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// Pseudo/virtual filesystems to skip, mirroring node_exporter's defaults.
/// tmpfs is intentionally kept (e.g. /run, /dev/shm are real usage).
const pseudo_fs = [_][]const u8{
    "autofs",    "binfmt_misc", "bpf",        "cgroup",     "cgroup2",
    "configfs",  "debugfs",     "devpts",     "devtmpfs",   "fusectl",
    "hugetlbfs", "mqueue",      "nsfs",       "overlay",    "proc",
    "procfs",    "pstore",      "rpc_pipefs", "securityfs", "selinuxfs",
    "squashfs",  "sysfs",       "tracefs",
};

fn isPseudoFs(fstype: []const u8) bool {
    for (pseudo_fs) |p| if (std.mem.eql(u8, fstype, p)) return true;
    return false;
}

const FsEntry = struct {
    device: []const u8,
    mountpoint: []const u8,
    fstype: []const u8,
    size: u64,
    free: u64,
    avail: u64,
    files: u64,
    files_free: u64,
};

fn collectFilesystem(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "mounts");
    defer ctx.gpa.free(data);

    var rows: [max_rows]FsEntry = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const device = f.next() orelse continue;
        const mountpoint = f.next() orelse continue; // may contain \ooo escapes
        const fstype = f.next() orelse continue;
        if (isPseudoFs(fstype)) continue;

        // statfs needs a NUL-terminated, unescaped path, prefixed by rootfs so a
        // container can statfs the host's mounts. The label keeps the raw form.
        var path_buf: [4096]u8 = undefined;
        const path = buildStatfsPath(ctx.rootfs, mountpoint, &path_buf) orelse continue;
        var st: Statfs = undefined;
        if (linux.errno(linux.syscall2(.statfs, @intFromPtr(path.ptr), @intFromPtr(&st))) != .SUCCESS) {
            continue; // unreadable mount (permissions, disconnected network fs, ...)
        }

        if (count >= rows.len) break;
        const bsize: u64 = if (st.f_bsize > 0) @intCast(st.f_bsize) else 0;
        rows[count] = .{
            .device = device,
            .mountpoint = mountpoint,
            .fstype = fstype,
            .size = st.f_blocks * bsize,
            .free = st.f_bfree * bsize,
            .avail = st.f_bavail * bsize,
            .files = st.f_files,
            .files_free = st.f_ffree,
        };
        count += 1;
    }
    const list = rows[0..count];

    try emitFs(sink, list, "node_filesystem_size_bytes", "Filesystem size in bytes.", .size);
    try emitFs(sink, list, "node_filesystem_free_bytes", "Filesystem free space in bytes.", .free);
    try emitFs(sink, list, "node_filesystem_avail_bytes", "Filesystem space available to non-root in bytes.", .avail);
    try emitFs(sink, list, "node_filesystem_files", "Total inodes.", .files);
    try emitFs(sink, list, "node_filesystem_files_free", "Free inodes.", .files_free);
}

fn emitFs(sink: Sink, list: []const FsEntry, name: []const u8, help: []const u8, comptime field: std.meta.FieldEnum(FsEntry)) anyerror!void {
    const m: Metric = .{ .name = name, .help = help, .kind = .gauge };
    for (list) |e| {
        try sink.emit(m, &.{
            .{ .name = "device", .value = e.device },
            .{ .name = "mountpoint", .value = e.mountpoint },
            .{ .name = "fstype", .value = e.fstype },
        }, .{ .int = @field(e, @tagName(field)) });
    }
}

/// Build the NUL-terminated path to statfs: `prefix` (rootfs) followed by the
/// mountpoint with `/proc/mounts` octal escapes decoded (`\040` -> space).
/// Returns null if the result would overflow `buf`.
fn buildStatfsPath(prefix: []const u8, mountpoint: []const u8, buf: []u8) ?[:0]const u8 {
    var j: usize = 0;
    for (prefix) |c| {
        if (j >= buf.len - 1) return null;
        buf[j] = c;
        j += 1;
    }
    var i: usize = 0;
    while (i < mountpoint.len) {
        if (j >= buf.len - 1) return null; // leave room for the NUL
        if (mountpoint[i] == '\\' and i + 4 <= mountpoint.len) {
            if (octalByte(mountpoint[i + 1 .. i + 4])) |b| {
                buf[j] = b;
                i += 4;
                j += 1;
                continue;
            }
        }
        buf[j] = mountpoint[i];
        i += 1;
        j += 1;
    }
    buf[j] = 0;
    return buf[0..j :0];
}

fn octalByte(digits: []const u8) ?u8 {
    var v: u16 = 0;
    for (digits) |d| {
        if (d < '0' or d > '7') return null;
        v = v * 8 + (d - '0');
    }
    return if (v <= 255) @intCast(v) else null;
}

// --- filefd ------------------------------------------------------------------

const FileNr = struct { allocated: u64, max: u64 };

/// `/proc/sys/fs/file-nr` is one line: "<allocated> <unused> <max>".
fn parseFileNr(data: []const u8) ?FileNr {
    var f = std.mem.tokenizeAny(u8, data, " \t\n");
    const allocated = f.next() orelse return null;
    _ = f.next() orelse return null; // unused (always 0 on modern kernels)
    const max = f.next() orelse return null;
    return .{
        .allocated = std.fmt.parseInt(u64, allocated, 10) catch return null,
        .max = std.fmt.parseInt(u64, max, 10) catch return null,
    };
}

fn collectFilefd(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "sys/fs/file-nr");
    defer ctx.gpa.free(data);
    const fnr = parseFileNr(data) orelse return error.MalformedFileNr;
    try sink.emit(.{ .name = "node_filefd_allocated", .help = "Allocated file descriptors.", .kind = .gauge }, &.{}, .{ .int = fnr.allocated });
    try sink.emit(.{ .name = "node_filefd_maximum", .help = "Maximum file descriptors.", .kind = .gauge }, &.{}, .{ .int = fnr.max });
}

// --- entropy -----------------------------------------------------------------

fn collectEntropy(ctx: Context, sink: Sink) anyerror!void {
    const avail = try readProc(ctx, "sys/kernel/random/entropy_avail");
    defer ctx.gpa.free(avail);
    const bits = std.fmt.parseInt(u64, std.mem.trim(u8, avail, " \t\n\r"), 10) catch return error.MalformedEntropy;
    try sink.emit(.{ .name = "node_entropy_available_bits", .help = "Available entropy in bits.", .kind = .gauge }, &.{}, .{ .int = bits });

    // Pool size is informative but optional; its absence must not fail the collector.
    if (readProc(ctx, "sys/kernel/random/poolsize")) |ps| {
        defer ctx.gpa.free(ps);
        if (std.fmt.parseInt(u64, std.mem.trim(u8, ps, " \t\n\r"), 10) catch null) |size| {
            try sink.emit(.{ .name = "node_entropy_pool_size_bits", .help = "Entropy pool size in bits.", .kind = .gauge }, &.{}, .{ .int = size });
        }
    } else |_| {}
}

// --- stat (non-CPU counters from /proc/stat) --------------------------------

/// Return the first numeric field of the `/proc/stat` line starting with `key`
/// (e.g. `key = "ctxt"` -> the context-switch counter). Null if absent.
fn statValue(data: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const k = f.next() orelse continue;
        if (!std.mem.eql(u8, k, key)) continue;
        const v = f.next() orelse return null;
        return std.fmt.parseInt(u64, v, 10) catch null;
    }
    return null;
}

fn collectStat(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "stat");
    defer ctx.gpa.free(data);

    if (statValue(data, "ctxt")) |n|
        try sink.emit(.{ .name = "node_context_switches_total", .help = "Context switches since boot.", .kind = .counter }, &.{}, .{ .int = n });
    if (statValue(data, "intr")) |n|
        try sink.emit(.{ .name = "node_intr_total", .help = "Interrupts serviced since boot.", .kind = .counter }, &.{}, .{ .int = n });
    if (statValue(data, "processes")) |n|
        try sink.emit(.{ .name = "node_forks_total", .help = "Forks since boot.", .kind = .counter }, &.{}, .{ .int = n });
    if (statValue(data, "procs_running")) |n|
        try sink.emit(.{ .name = "node_procs_running", .help = "Processes in runnable state.", .kind = .gauge }, &.{}, .{ .int = n });
    if (statValue(data, "procs_blocked")) |n|
        try sink.emit(.{ .name = "node_procs_blocked", .help = "Processes blocked on I/O.", .kind = .gauge }, &.{}, .{ .int = n });
    if (statValue(data, "btime")) |n|
        try sink.emit(.{ .name = "node_boot_time_seconds", .help = "Unix time of system boot.", .kind = .gauge }, &.{}, .{ .int = n });
}

// --- uname -------------------------------------------------------------------

/// node_uname_info carries the host/kernel identity as label values. uname(2) is
/// a syscall (not a /proc read), and in a container it returns the *host* kernel,
/// so it needs no procfs base.
fn collectUname(ctx: Context, sink: Sink) anyerror!void {
    _ = ctx;
    const uts = std.posix.uname();
    try sink.emit(
        .{ .name = "node_uname_info", .help = "Labeled system information from uname(2).", .kind = .gauge },
        &.{
            .{ .name = "sysname", .value = std.mem.sliceTo(&uts.sysname, 0) },
            .{ .name = "release", .value = std.mem.sliceTo(&uts.release, 0) },
            .{ .name = "version", .value = std.mem.sliceTo(&uts.version, 0) },
            .{ .name = "machine", .value = std.mem.sliceTo(&uts.machine, 0) },
            .{ .name = "nodename", .value = std.mem.sliceTo(&uts.nodename, 0) },
            .{ .name = "domainname", .value = std.mem.sliceTo(&uts.domainname, 0) },
        },
        .{ .int = 1 },
    );
}

// --- sockstat ----------------------------------------------------------------

fn collectSockstat(ctx: Context, sink: Sink) anyerror!void {
    const data = try readProc(ctx, "net/sockstat");
    defer ctx.gpa.free(data);
    try emitSockstat(data, sink);
}

/// Each `/proc/net/sockstat` line is "Proto: key val key val ...". Emit one
/// gauge per pair: `node_sockstat_<Proto>_<key>`.
fn emitSockstat(data: []const u8, sink: Sink) anyerror!void {
    var name_buf: [128]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const proto = line[0..colon];
        var f = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        while (true) {
            const key = f.next() orelse break;
            const val_str = f.next() orelse break;
            const val = std.fmt.parseInt(u64, val_str, 10) catch continue;
            const name = std.fmt.bufPrint(&name_buf, "node_sockstat_{s}_{s}", .{ proto, key }) catch continue;
            try sink.emit(.{ .name = name, .help = "Socket usage from /proc/net/sockstat.", .kind = .gauge }, &.{}, .{ .int = val });
        }
    }
}

// --- netstat (curated /proc/net/snmp + /proc/net/netstat) --------------------

/// A curated allowlist keeps cardinality sane — these files carry ~150 fields.
const netstat_allow = [_][2][]const u8{
    .{ "Tcp", "ActiveOpens" },        .{ "Tcp", "PassiveOpens" },
    .{ "Tcp", "CurrEstab" },          .{ "Tcp", "InSegs" },
    .{ "Tcp", "OutSegs" },            .{ "Tcp", "RetransSegs" },
    .{ "Tcp", "InErrs" },             .{ "Tcp", "EstabResets" },
    .{ "Udp", "InDatagrams" },        .{ "Udp", "OutDatagrams" },
    .{ "Udp", "InErrors" },           .{ "Udp", "NoPorts" },
    .{ "TcpExt", "ListenOverflows" }, .{ "TcpExt", "ListenDrops" },
    .{ "TcpExt", "SyncookiesSent" },
};

fn netstatAllowed(proto: []const u8, field: []const u8) bool {
    for (netstat_allow) |p| {
        if (std.mem.eql(u8, proto, p[0]) and std.mem.eql(u8, field, p[1])) return true;
    }
    return false;
}

fn collectNetstat(ctx: Context, sink: Sink) anyerror!void {
    const snmp = try readProc(ctx, "net/snmp");
    defer ctx.gpa.free(snmp);
    try emitNetstat(snmp, sink);

    // TcpExt lives in a separate file; its absence must not fail the collector.
    if (readProc(ctx, "net/netstat")) |ns| {
        defer ctx.gpa.free(ns);
        try emitNetstat(ns, sink);
    } else |_| {}
}

/// snmp/netstat format: alternating header and value lines sharing a proto tag,
/// e.g. "Tcp: ActiveOpens ..." then "Tcp: 100 ...". Zip them, emit allowlisted.
fn emitNetstat(data: []const u8, sink: Sink) anyerror!void {
    var name_buf: [128]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (true) {
        const header = lines.next() orelse break;
        const values = lines.next() orelse break;
        const hc = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const vc = std.mem.indexOfScalar(u8, values, ':') orelse continue;
        const proto = header[0..hc];
        if (!std.mem.eql(u8, proto, values[0..vc])) continue; // header/value misaligned

        var hf = std.mem.tokenizeAny(u8, header[hc + 1 ..], " \t");
        var vf = std.mem.tokenizeAny(u8, values[vc + 1 ..], " \t");
        while (true) {
            const field = hf.next() orelse break;
            const val_str = vf.next() orelse break;
            if (!netstatAllowed(proto, field)) continue;
            const val = std.fmt.parseInt(u64, val_str, 10) catch continue; // negatives (e.g. MaxConn) not in allowlist
            const name = std.fmt.bufPrint(&name_buf, "node_netstat_{s}_{s}", .{ proto, field }) catch continue;
            const kind: metric.Kind = if (std.mem.eql(u8, field, "CurrEstab")) .gauge else .counter;
            try sink.emit(.{ .name = name, .help = "Network statistic from /proc/net.", .kind = kind }, &.{}, .{ .int = val });
        }
    }
}

// --- thermal (sysfs) ---------------------------------------------------------

/// Enumerate `<sysfs>/class/thermal/thermal_zone*`, reading each zone's `temp`
/// (millidegrees C) and `type`. This is the first collector that iterates a
/// directory and reads /sys, so it uses the `sysfs` base path.
fn collectThermal(ctx: Context, sink: Sink) anyerror!void {
    var dir_path_buf: [4096]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buf, "{s}/class/thermal", .{ctx.sysfs});
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true });
    defer dir.close(ctx.io);

    const m: Metric = .{ .name = "node_thermal_zone_temp", .help = "Thermal zone temperature in Celsius.", .kind = .gauge };
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "thermal_zone")) continue;
        const zone = entry.name["thermal_zone".len..]; // the trailing number

        var sub_buf: [256]u8 = undefined;
        const temp_sub = std.fmt.bufPrint(&sub_buf, "class/thermal/{s}/temp", .{entry.name}) catch continue;
        const temp_data = readSys(ctx, temp_sub) catch continue; // some zones expose no temp
        defer ctx.gpa.free(temp_data);
        const milli = std.fmt.parseInt(i64, std.mem.trim(u8, temp_data, " \t\n\r"), 10) catch continue;

        var type_buf: [256]u8 = undefined;
        const type_sub = std.fmt.bufPrint(&type_buf, "class/thermal/{s}/type", .{entry.name}) catch continue;
        const type_data = readSys(ctx, type_sub) catch continue;
        defer ctx.gpa.free(type_data);
        const ztype = std.mem.trim(u8, type_data, " \t\n\r");

        const celsius = @as(f64, @floatFromInt(milli)) / 1000.0;
        try sink.emit(m, &.{ .{ .name = "zone", .value = zone }, .{ .name = "type", .value = ztype } }, .{ .float = celsius });
    }
}

// --- tests -------------------------------------------------------------------

/// A sink that records emitted samples as "name{labels} value" lines, for tests.
const TestSink = struct {
    w: *std.Io.Writer,
    fn sink(self: *TestSink) Sink {
        return .{ .ptr = self, .emitFn = emit };
    }
    fn emit(ptr: *anyopaque, m: Metric, labels: []const Label, value: metric.Value) anyerror!void {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        try self.w.writeAll(m.name);
        for (labels) |l| try self.w.print("{{{s}={s}}}", .{ l.name, l.value });
        switch (value) {
            .int => |v| try self.w.print(" {d}\n", .{v}),
            .float => |v| try self.w.print(" {d}\n", .{v}),
        }
    }
};

test "parseMeminfoLine: standard kB line" {
    const got = parseMeminfoLine("MemTotal:       16384000 kB").?;
    try std.testing.expectEqualStrings("MemTotal", got.key);
    try std.testing.expectEqual(@as(u64, 16384000), got.kb);
}

test "parseMeminfoLine: no-unit line still parses" {
    const got = parseMeminfoLine("HugePages_Total:       0").?;
    try std.testing.expectEqualStrings("HugePages_Total", got.key);
    try std.testing.expectEqual(@as(u64, 0), got.kb);
}

test "parseMeminfoLine: junk returns null" {
    try std.testing.expect(parseMeminfoLine("not a meminfo line") == null);
    try std.testing.expect(parseMeminfoLine("") == null);
}

test "parseNetdevLine: typical interface line" {
    const line = "  eth0: 100 2 0 0 0 0 0 0 200 3 0 0 0 0 0 0";
    const e = parseNetdevLine(line).?;
    try std.testing.expectEqualStrings("eth0", e.iface);
    try std.testing.expectEqual(@as(u64, 100), e.s.rx_bytes);
    try std.testing.expectEqual(@as(u64, 2), e.s.rx_packets);
    try std.testing.expectEqual(@as(u64, 200), e.s.tx_bytes);
    try std.testing.expectEqual(@as(u64, 3), e.s.tx_packets);
}

test "parseNetdevLine: header line has no colon -> null" {
    try std.testing.expect(parseNetdevLine("Inter-|   Receive        |  Transmit") == null);
}

test "parseDiskstatsLine: reads sectors and skips major/minor" {
    // major minor name reads rmerged sread ms_read writes wmerged swritten ms_write ...
    const line = "   8       0 sda 10 0 200 5 20 0 400 6 0 30 40";
    const e = parseDiskstatsLine(line).?;
    try std.testing.expectEqualStrings("sda", e.name);
    try std.testing.expectEqual(@as(u64, 10), e.s.reads);
    try std.testing.expectEqual(@as(u64, 200), e.s.read_sectors);
    try std.testing.expectEqual(@as(u64, 20), e.s.writes);
    try std.testing.expectEqual(@as(u64, 400), e.s.written_sectors);
    try std.testing.expectEqual(@as(u64, 30), e.s.io_ms);
}

test "isNoiseDisk filters loop/ram only" {
    try std.testing.expect(isNoiseDisk("loop0"));
    try std.testing.expect(isNoiseDisk("ram3"));
    try std.testing.expect(!isNoiseDisk("sda"));
    try std.testing.expect(!isNoiseDisk("nvme0n1"));
}

test "psiTotal extracts the total for some/full" {
    const data =
        \\some avg10=0.00 avg60=0.10 avg300=0.05 total=123456
        \\full avg10=0.00 avg60=0.00 avg300=0.00 total=789
        \\
    ;
    try std.testing.expectEqual(@as(u64, 123456), psiTotal(data, "some").?);
    try std.testing.expectEqual(@as(u64, 789), psiTotal(data, "full").?);
    try std.testing.expect(psiTotal("some avg10=0.00", "some") == null); // no total=
}

test "Statfs matches the kernel 64-bit layout" {
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(Statfs));
}

test "isPseudoFs keeps real filesystems, drops virtual ones" {
    try std.testing.expect(isPseudoFs("proc"));
    try std.testing.expect(isPseudoFs("sysfs"));
    try std.testing.expect(isPseudoFs("overlay"));
    try std.testing.expect(!isPseudoFs("ext4"));
    try std.testing.expect(!isPseudoFs("xfs"));
    try std.testing.expect(!isPseudoFs("tmpfs")); // kept on purpose
}

test "octalByte parses valid octal, rejects the rest" {
    try std.testing.expectEqual(@as(u8, ' '), octalByte("040").?);
    try std.testing.expectEqual(@as(u8, '\\'), octalByte("134").?);
    try std.testing.expect(octalByte("999") == null); // 9 not octal
    try std.testing.expect(octalByte("400") == null); // 256 > 255
}

test "buildStatfsPath: decodes escapes, applies rootfs prefix, NUL-terminates" {
    var buf: [64]u8 = undefined;

    // no prefix, with an escaped space
    const p1 = buildStatfsPath("", "/mnt/my\\040disk", &buf).?;
    try std.testing.expectEqualStrings("/mnt/my disk", p1);
    try std.testing.expectEqual(@as(u8, 0), p1.ptr[p1.len]); // sentinel present

    // rootfs prefix for container host-monitoring
    const p2 = buildStatfsPath("/host/root", "/home", &buf).?;
    try std.testing.expectEqualStrings("/host/root/home", p2);
}

test "parseFileNr: allocated + max, ignoring the middle field" {
    const fnr = parseFileNr("1216\t0\t9223372036854775807\n").?;
    try std.testing.expectEqual(@as(u64, 1216), fnr.allocated);
    try std.testing.expectEqual(@as(u64, 9223372036854775807), fnr.max);
    try std.testing.expect(parseFileNr("1216 0") == null); // missing max
}

test "statValue: matches key exactly and takes first field" {
    const data =
        \\cpu  1 2 3 4 5 6 7 8
        \\cpu0 1 2 3 4 5 6 7 8
        \\intr 987654 0 0 0
        \\ctxt 12345678
        \\btime 1700000000
        \\processes 90210
        \\procs_running 3
        \\procs_blocked 0
        \\
    ;
    try std.testing.expectEqual(@as(u64, 12345678), statValue(data, "ctxt").?);
    try std.testing.expectEqual(@as(u64, 987654), statValue(data, "intr").?);
    try std.testing.expectEqual(@as(u64, 90210), statValue(data, "processes").?);
    try std.testing.expectEqual(@as(u64, 3), statValue(data, "procs_running").?);
    try std.testing.expectEqual(@as(u64, 1700000000), statValue(data, "btime").?);
    try std.testing.expect(statValue(data, "nope") == null);
    // must not match "cpu" as a prefix of "cpu0"
    try std.testing.expectEqual(@as(u64, 1), statValue(data, "cpu").?);
}

test "emitSockstat: one gauge per key/val pair" {
    const data =
        \\sockets: used 500
        \\TCP: inuse 10 orphan 0 tw 5 alloc 20 mem 3
        \\UDP: inuse 8 mem 2
        \\
    ;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ts = TestSink{ .w = &w };
    try emitSockstat(data, ts.sink());
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "node_sockstat_sockets_used 500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "node_sockstat_TCP_inuse 10\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "node_sockstat_TCP_alloc 20\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "node_sockstat_UDP_mem 2\n") != null);
}

test "emitNetstat: zips header/values, applies allowlist" {
    const data =
        \\Tcp: RtoAlgorithm RtoMin MaxConn ActiveOpens PassiveOpens CurrEstab RetransSegs
        \\Tcp: 1 200 -1 111 22 8 3
        \\Udp: InDatagrams NoPorts OutDatagrams
        \\Udp: 900 4 800
        \\
    ;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ts = TestSink{ .w = &w };
    try emitNetstat(data, ts.sink());
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "node_netstat_Tcp_ActiveOpens 111\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "node_netstat_Tcp_CurrEstab 8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "node_netstat_Udp_NoPorts 4\n") != null);
    // non-allowlisted fields must be skipped
    try std.testing.expect(std.mem.indexOf(u8, out, "RtoAlgorithm") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MaxConn") == null);
}
