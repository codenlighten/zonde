//! Sink that streams OTLP/JSON (ExportMetricsServiceRequest) as samples arrive.
//!
//! We build the JSON incrementally rather than accumulating structs: each metric
//! family opens one `metrics[]` object (a `gauge` or a cumulative monotonic
//! `sum`), and each sample appends a data point. This keeps the exporter
//! allocation-light (only the growing output buffer) and needs no protobuf.
//!
//! Encoding follows the proto3 JSON mapping OTLP requires: 64-bit integers
//! (`timeUnixNano`, `asInt`) are JSON strings; `asDouble` is a JSON number.

const std = @import("std");
const metric = @import("metric.zig");
const Writer = std.Io.Writer;

pub const OtlpSink = struct {
    w: *Writer,
    ts_nano: i96,
    service_name: []const u8,

    started: bool = false, // preamble written
    metric_open: bool = false, // a metrics[] object is open
    dp_written: bool = false, // a data point exists in the current object
    cur_name: []const u8 = &.{},

    pub fn init(w: *Writer, ts_nano: i96, service_name: []const u8) OtlpSink {
        return .{ .w = w, .ts_nano = ts_nano, .service_name = service_name };
    }

    pub fn sink(self: *OtlpSink) metric.Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    /// Close all open JSON scopes. Must be called once after `scrape`.
    pub fn finish(self: *OtlpSink) Writer.Error!void {
        if (!self.started) {
            try self.w.writeAll("{\"resourceMetrics\":[]}");
            return;
        }
        if (self.metric_open) try self.w.writeAll("]}}"); // dataPoints, kind obj, metric obj
        try self.w.writeAll("]}]}]}"); // metrics, scope obj, scopeMetrics, resource obj, resourceMetrics, root
    }

    fn ensurePreamble(self: *OtlpSink) Writer.Error!void {
        if (self.started) return;
        self.started = true;
        const w = self.w;
        try w.writeAll("{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
        try writeJsonString(w, self.service_name);
        try w.writeAll("\"}}]},\"scopeMetrics\":[{\"scope\":{\"name\":\"zonde\"},\"metrics\":[");
    }

    fn emit(ptr: *anyopaque, m: metric.Metric, labels: []const metric.Label, value: metric.Value) anyerror!void {
        const self: *OtlpSink = @ptrCast(@alignCast(ptr));
        const w = self.w;
        try self.ensurePreamble();

        if (!self.metric_open or !std.mem.eql(u8, m.name, self.cur_name)) {
            if (self.metric_open) try w.writeAll("]}},"); // close prev group + separator
            try w.writeAll("{\"name\":\"");
            try writeJsonString(w, m.name);
            try w.writeAll("\",\"description\":\"");
            try writeJsonString(w, m.help);
            try w.writeAll("\",");
            switch (m.kind) {
                .gauge => try w.writeAll("\"gauge\":{\"dataPoints\":["),
                .counter => try w.writeAll("\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":["),
            }
            self.metric_open = true;
            self.cur_name = m.name;
            self.dp_written = false;
        }

        if (self.dp_written) try w.writeByte(',');
        try w.writeAll("{\"timeUnixNano\":\"");
        try w.print("{d}", .{self.ts_nano});
        try w.writeAll("\",\"attributes\":[");
        for (labels, 0..) |l, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"key\":\"");
            try writeJsonString(w, l.name);
            try w.writeAll("\",\"value\":{\"stringValue\":\"");
            try writeJsonString(w, l.value);
            try w.writeAll("\"}}");
        }
        try w.writeAll("],");
        switch (value) {
            .int => |v| {
                try w.writeAll("\"asInt\":\"");
                try w.print("{d}", .{v});
                try w.writeByte('"');
            },
            .float => |v| {
                try w.writeAll("\"asDouble\":");
                try w.print("{d}", .{v});
            },
        }
        try w.writeByte('}');
        self.dp_written = true;
    }
};

fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.writeAll("\\u00");
            try w.writeByte(hex[(c >> 4) & 0xf]);
            try w.writeByte(hex[c & 0xf]);
        } else try w.writeByte(c),
    };
}

test "writeJsonString escapes control and quote chars" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeJsonString(&w, "a\"b\\c\n");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\n", w.buffered());
}
