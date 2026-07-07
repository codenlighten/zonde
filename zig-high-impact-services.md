# Top 10 Services That Would Be a Massive Contribution if Built in Zig

Ranked by **impact × fit with Zig's strengths** (predictable performance, no hidden
allocation, tiny binaries, trivial cross-compilation, painless C interop). Favoring
areas where Zig would be genuinely *better*, not just "rewrite X in Zig."

The pattern behind the ranking: **Zig wins most where the workload is latency-sensitive,
memory-constrained, needs a C ABI so other languages benefit, or wraps existing C
libraries.** The biggest *contributions* expose a C ABI (#1, #5, #7), because a single
Zig core then lifts *every* language's ecosystem, not just Zig's.

Proof points that already exist: **TigerBeetle** (database), **Bun** (runtime),
**`zig cc`** (toolchain).

| # | Service | Why Zig fits |
|---|---------|--------------|
| 1 | **Universal database driver / connection-pooling layer** | One Zig lib speaking Postgres, MySQL, Redis, SQLite wire protocols natively, with a C ABI so *every* language can bind to it. Highest-leverage item — benefits all ecosystems at once. |
| 2 | **Edge / serverless runtime (WASM host or micro-container)** | Tiny dependency-free binaries + compiles to WASM. Cold-start latency is where Zig visibly wins vs. JVM/Node. |
| 3 | **Message broker / event streaming engine** | Kafka/NATS/RabbitMQ-class. Brokers die on tail latency and GC pauses; Zig has no GC and hand-tunable memory layout. |
| 4 | **Reverse proxy / API gateway / load balancer** | Envoy/Nginx/HAProxy alternative. Pure throughput+latency, heavy C interop (TLS, HTTP/2, QUIC) — `@cImport` makes wrapping BoringSSL/quiche trivial. |
| 5 | **Embedded / edge database or storage engine** | SQLite-class embeddable DB or modern LSM/B-tree engine via C ABI. TigerBeetle already proves this is arguably Zig's single best-fit domain. |
| 6 | **Cross-platform runtime for a higher-level language** | VM/GC + stdlib for a scripting language. Manual memory for the GC, comptime for dispatch tables, cross-compile everywhere. Bun proved the model. |
| 7 | **TLS / cryptography library with a clean C ABI** | Auditable, allocation-transparent OpenSSL alternative. Crypto needs constant-time code and zero surprises — Zig's "no hidden control flow" ethos. |
| 8 | **Observability agent / telemetry collector** | One tiny binary replacing node-exporter + OTel collector + Fluentd/Vector. Agents run on every host; a 2 MB low-RSS cross-compiled binary is a real win. |
| 9 | **Build system / package toolchain for the broader ecosystem** | Extend `zig cc` into a full polyglot hermetic cross-compile toolchain. Already adopted outside the Zig community. |
| 10 | **Game engine / real-time media core** | Engine core, audio pipeline, video transcoding. Deterministic per-frame budgets (no GC) + heavy C interop (FFmpeg, Vulkan, SDL). |

---
*Compiled 2026-07-07.*
