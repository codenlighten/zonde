//! Sink that renders samples as Prometheus text exposition format.
//!
//! Emits a HELP/TYPE header the first time a metric name is seen, then one line
//! per sample. Relies on the family-by-family emission contract in `metric.zig`
//! so each family's HELP appears exactly once.

const std = @import("std");
const metric = @import("metric.zig");
const Writer = std.Io.Writer;

pub const PromSink = struct {
    w: *Writer,
    last_name: []const u8 = &.{},

    pub fn sink(self: *PromSink) metric.Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, m: metric.Metric, labels: []const metric.Label, value: metric.Value) anyerror!void {
        const self: *PromSink = @ptrCast(@alignCast(ptr));
        const w = self.w;

        if (!std.mem.eql(u8, m.name, self.last_name)) {
            try w.print("# HELP {s} {s}\n# TYPE {s} {s}\n", .{ m.name, m.help, m.name, @tagName(m.kind) });
            self.last_name = m.name;
        }

        try w.writeAll(m.name);
        if (labels.len > 0) {
            try w.writeByte('{');
            for (labels, 0..) |l, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{s}=\"{s}\"", .{ l.name, l.value });
            }
            try w.writeByte('}');
        }
        switch (value) {
            .int => |v| try w.print(" {d}\n", .{v}),
            .float => |v| try w.print(" {d}\n", .{v}),
        }
    }
};
