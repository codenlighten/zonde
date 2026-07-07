# zonde ⚡

A tiny, zero-dependency, cross-compiled **observability agent** in Zig — one small
binary aiming to collapse `node-exporter` + OTel collector + Vector into a single
low-RSS process.

Status: **M4** — configurable, cross-compiled, container-ready. Pull (`/metrics`) *and*
push (OTLP/JSON) with host + network + disk + PSI collectors.
See [`DECISION.md`](DECISION.md) for the why and the roadmap.

## Build & run

```sh
zig build run                                   # serve /metrics on http://0.0.0.0:9100
zig build run -- --once                         # print one scrape to stdout and exit
zig build run -- --port 9464                    # listen on a different port
zig build run -- --otlp http://collector:4318/v1/metrics --interval 15   # OTLP push (agent mode)
zig build test                                  # run unit tests
zig build -Doptimize=ReleaseSmall               # native binary
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-musl   # static ARM64
```

Then scrape it: `curl localhost:9100/metrics`. Requires Zig `0.16.0` (uses `std.Io`).

## Configuration

Precedence is **flags > env > defaults**:

| Flag | Env var | Default |
|---|---|---|
| `--listen ADDR` | `ZONDE_LISTEN_ADDR` | `0.0.0.0` |
| `--port N` | `ZONDE_PORT` | `9100` |
| `--otlp URL` | `ZONDE_OTLP_ENDPOINT` | (unset → pull mode) |
| `--interval S` | `ZONDE_INTERVAL` | `60` |

## Release & container

```sh
zig build release      # stripped ReleaseSmall for linux {x86_64,aarch64}×{gnu,musl}
                       # into zig-out/release/, gated at a 2 MiB size budget
docker build --build-arg TARGET=x86_64-linux-musl -t zonde .   # FROM scratch, ~585 kB image
```

## Two ways to ship metrics

- **Pull:** Prometheus scrapes `GET /metrics`.
- **Push:** `--otlp URL` periodically POSTs OTLP/JSON (`ExportMetricsServiceRequest`) to any
  OpenTelemetry collector. Same collectors, two outputs — via a `metric.Sink` abstraction
  (`sink_prom.zig` / `sink_otlp.zig`) so adding a format never touches collector code.

## Endpoints

| Path | Description |
|---|---|
| `GET /metrics` | Prometheus text exposition (`text/plain; version=0.0.4`) |
| `GET /health` | liveness check |
| non-GET/HEAD | `405 method not allowed` |

## What it exposes today

| Collector | Metrics | Source |
|---|---|---|
| memory | `node_memory_*_bytes` (gauge) | `/proc/meminfo` |
| cpu | `node_cpu_seconds_total{cpu,mode}` (counter) | `/proc/stat` |
| loadavg | `node_load{1,5,15}` (gauge) | `/proc/loadavg` |
| netdev | `node_network_{receive,transmit}_{bytes,packets,errs,drop}_total{device}` (counter) | `/proc/net/dev` |
| diskstats | `node_disk_{reads,writes}_completed_total`, `node_disk_{read,written}_bytes_total`, `node_disk_io_time_seconds_total{device}` (counter) | `/proc/diskstats` |
| pressure | `node_pressure_{cpu,memory,io}_{waiting,stalled}_seconds_total` (counter) | `/proc/pressure/*` |
| filesystem | `node_filesystem_{size,free,avail}_bytes`, `node_filesystem_files{,_free}{device,mountpoint,fstype}` (gauge) | `/proc/mounts` + `statfs(2)` |

Plus `zonde_up` and, on any collector failure, `zonde_collector_error{collector,error}` (the
scrape still succeeds). Adding a collector = one parse function + one `registry` entry.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on push/PR:

1. **check** — `zig fmt --check src build.zig` and `zig build test`.
2. **release** — `zig build release` (the size-gated cross-compile matrix), then uploads the
   binaries as an artifact. A dependency that pushes any target over 2 MiB fails the build.

Zig is pinned to `0.16.0` (matches `build.zig.zon`'s `minimum_zig_version`).

## Design notes

- **`Io` is threaded, never global** — `main` receives `std.process.Init`; `io` and the
  allocator are passed explicitly to every collector, mirroring Zig's allocator idiom.
- **Collectors degrade independently** — one failing `/proc` read surfaces as a
  `zonde_collector_error` metric instead of aborting the scrape.
- **`/proc` files stream to EOF** — they report `st_size == 0`, so we read via
  `allocRemaining`, not `readFileAlloc`.
