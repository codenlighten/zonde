//! The structured metric model that decouples collectors from output formats.
//!
//! Collectors emit samples into a type-erased `Sink`; concrete sinks render to
//! Prometheus text (`sink_prom`) or OTLP/JSON (`sink_otlp`). This is what lets
//! one set of collectors serve both the pull endpoint and the push exporter.

const std = @import("std");

pub const Kind = enum { gauge, counter };

/// Keep integer counters exact rather than forcing everything through f64
/// (which would lose precision past 2^53 for things like byte counters).
pub const Value = union(enum) {
    int: u64,
    float: f64,
};

pub const Label = struct { name: []const u8, value: []const u8 };

pub const Metric = struct {
    name: []const u8,
    help: []const u8,
    kind: Kind,
};

/// A type-erased destination for metric samples.
///
/// Contract: a collector emits all samples of one metric family consecutively
/// (family-by-family). Sinks rely on this to group output — Prometheus writes a
/// single HELP/TYPE per family; OTLP opens one metric object per family.
pub const Sink = struct {
    ptr: *anyopaque,
    emitFn: *const fn (*anyopaque, Metric, []const Label, Value) anyerror!void,

    pub fn emit(sink: Sink, metric: Metric, labels: []const Label, value: Value) anyerror!void {
        return sink.emitFn(sink.ptr, metric, labels, value);
    }
};
