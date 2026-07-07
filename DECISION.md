# zonde — decision record & roadmap

**Date:** 2026-07-07
**Toolchain:** Zig `0.16.0-dev.3153+d6f43caad` (ships the 0.16.0 release std, dated Apr 13)

## What we're building

**`zonde`** — a tiny, zero-dependency, cross-compiled **observability agent**. One
~2 MB binary that collapses `node-exporter` + OTel collector + Vector into a single
low-RSS process. A *sonde* is a telemetry probe; the name fits.

## Why this, over the alternatives

We ranked our candidate projects on two axes: **impact × Zig-fit** (the original list)
*and* **winnability** (adoption path, trust barrier, scope realism, incumbent strength).
`zonde` wins on the risk-adjusted score:

- **Day-one value** — even a v0.1 that only replaces `node-exporter` is useful to someone.
- **Low trust barrier** — nobody has to audit a metrics agent the way they'd audit a
  crypto lib or a database engine.
- **Clean incremental "done"** — collectors, then exposition, then OTLP push, then config.
- **Proven lane, still open** — Vector (Rust) validated the model (acq. by Datadog); OTel
  is a standard we implement piece by piece. Room for a 2 MB, zero-dep, cross-compiled agent.
- **0.16 tailwind** — the new `std.Io` async interface means the network/scheduling core is
  stdlib, not something we hand-roll.

The **embeddable storage engine** (C-ABI LSM/B-tree) remains our highest-*ceiling* idea and
stays in the back pocket — it just has a much longer road to first value.

## Roadmap

- [x] **M0 — Slice:** read Linux `/proc` (memory, CPU, loadavg) and render Prometheus text
      exposition format to stdout. *Proves the toolchain + shape.*
- [x] **M1 — Serve:** expose `/metrics` over HTTP using `std.Io` + `std.http.Server`
      (also `/health`; `--once` keeps the stdout mode). Keep-alive, HEAD, and method
      rejection handled. ← we are here
- [x] **M2 — Collectors:** collector registry + netdev, diskstats, pressure/PSI added
      (memory/cpu/loadavg refactored into it). Per-device families grouped correctly,
      alloc-free parsing, unit-tested parsers. Filesystem (needs a statfs syscall wrapper,
      not just a /proc read) deferred to its own step. ← we are here
- [x] **M3 — Push:** OTLP/HTTP JSON exporter (`--otlp URL [--interval S]`). A `metric.Sink`
      abstraction now decouples collectors from output; the same collectors feed both the
      Prometheus text endpoint and the OTLP push. Verified against a mock collector: valid
      JSON, cumulative-monotonic sums, gauge doubles. ← we are here
- [x] **M4 — Config + cross-compile matrix:** env+flag config (flags > `ZONDE_*` env >
      defaults) in config.zig; `zig build release` builds stripped ReleaseSmall for
      linux-{x86_64,aarch64}×{gnu,musl} with a 2 MiB size-budget gate; `FROM scratch`
      Dockerfile → ~585 kB image. ← we are here

- [x] **Filesystem collector:** `node_filesystem_*` (size/free/avail/files) via a raw
      `statfs(2)` syscall over `/proc/mounts` (pseudo-fs filtered, octal-escape decoding).
      Verified against `df`; compiles for x86_64 + aarch64 (per-arch syscall numbers).
- [x] **CI:** `.github/workflows/ci.yml` — `zig fmt --check` + `zig build test`, then the
      size-gated `zig build release` matrix with artifact upload. All steps verified green
      locally from a clean cache. (Runs once the repo has a GitHub remote.)

## Non-goals (for now)

Logs and traces pipelines (start metrics-only), Windows/macOS collectors (Linux first),
and a plugin system (compile-time collector registry is enough).
