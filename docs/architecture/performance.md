# Performance

Concrete budget gates, what we measure, where the measurements live, and what to do when a regression lands.

ADR cross-references: 0021 (the budget itself: Linux-kernel scale), 0024 (fsmonitor integration is load-bearing for the budget), 0026 (Scalar-style git defaults). See also [`fs-watching.md`](fs-watching.md), [`git-backend.md`](git-backend.md).

## Budget targets (ADR 0021)

Sprig must hit these on a **100k-file repo** (Linux kernel scale) with a typical user workflow:

| Metric | Budget | Notes |
|---|---|---|
| Steady-state agent CPU | < 2% on one core | Idle watcher + IPC poll only. `git status` queries spike higher; budget is the *long-term* average. |
| Agent RAM | < 150 MB resident | Dirty-set + badge trie + `cat-file --batch` cache for the largest watched repo. |
| Badge update latency | < 100 ms | From `git` write completion to FinderSync/Explorer badge re-render. End-to-end. |
| `git status` (cold) | < 1 s | First call after agent start; warms `core.fsmonitor`. |
| `git status` (warm) | < 100 ms | Subsequent calls; via `core.fsmonitor` should be O(changed paths). |
| Cold start | < 500 ms | Agent process launch → ready to serve IPC. |

These are gates that block 1.0 — we don't ship if any of them are red on the kernel-scale fixture. They do not gate every PR; the benchmark suite runs nightly on a self-hosted runner (see [`../ci/self-hosted.md`](../ci/self-hosted.md)) plus on demand via a workflow-dispatch.

## How we hit the targets

1. **`core.fsmonitor` hook** (ADR 0024). Without it, `git status` walks the whole tree on every call, so even a fast watcher can't help the user's terminal. With Sprig as the fsmonitor source of truth, `git status` becomes O(changed-since-last-tick) for everyone.
2. **Long-lived `git cat-file --batch`** (`GitCore.CatFileBatch`). Object reads are pipe round-trips, not fork-exec.
3. **`EventCoalescer`** (100–250 ms tick window). Editor saves emit 2–4 events in a few ms; we collapse to one per path before doing any `git status` work.
4. **Path trie for badge lookups.** O(log n) instead of O(n) when the FinderSync extension asks "badge for `<path>`?"
5. **`feature.manyFiles` + commit-graph + multi-pack-index** auto-applied to managed repos (ADR 0026). Speeds up `git log` and ancestry queries.
6. **`--porcelain=v2 -z` everywhere.** Single git invocation, deterministic byte format, no per-line forking.

## Benchmark suite (`Benchmarks/SprigCoreBenchmarks/`)

**Harness:** [`ordo-one/package-benchmark`](https://github.com/ordo-one/package-benchmark). Linux + macOS friendly, integrates with SwiftPM, supports JMH-format output for trend tracking. Threshold-based regression detection (configurable per benchmark) gates the nightly compare workflow; PR runs are smoke-build only (the target compiles on every macOS + Linux CI run).

**Why not Windows:** package-benchmark relies on filename conventions (benchmark-name → file path) that collide with NTFS reserved characters. Windows is out for benchmarks until `ordo-one/package-benchmark#308` lands; the `Package.swift` excludes the benchmark target on Windows via `#if os(Windows)`.

**System dependency:** `jemalloc` is required on both macOS and Linux for the malloc-tracking metric (resolved via `pkg-config` against the system install — no vendored shim). CI installs it (`brew install jemalloc` on macOS, `apt-get install libjemalloc-dev` on Linux); `script/bootstrap` warns if it's missing locally.

**Metric units:** wall-clock via `mach_absolute_time` / `clock_gettime`; CPU via `getrusage`; malloc via jemalloc instrumentation; RSS via `task_info` / `/proc/self/statm`. `package-benchmark` wraps these.

**Synthesized 100k-file repo:** generated on demand in a temp dir; not vendored. Faster CI than checking in a multi-GB fixture, and reproducible.

Initial benchmark set (M1 deliverable):

- ✅ `PorcelainV2Parser.parse` against synthesized 1k / 10k / 100k entry buffers.
- ✅ `LogParser.parse` against synthesized 1k / 10k commits (NUL-terminated, U+001F-separated, matches `git log -z --format=<LogParser.formatString>`).
- ✅ `EventCoalescer` round-trip throughput (ingest → drain) at 1k / 10k events.
- ✅ `PollingFileWatcher.takeSnapshot` against synthesized 1k / 10k / 100k file trees (two-level fanout, `tmpfs` on Linux CI).
- ✅ End-to-end `Runner.run + PorcelainV2Parser.parse` against synthesized 1k / 10k file repos (10 % worktree-dirty fraction, two-level fanout). 100k-file scale deferred to the self-hosted nightly workflow.

Later additions:

- `FSEventsWatcher` cold-start latency (macOS only; needs a self-hosted runner because the github-hosted runner virtualizes FSEvents in ways that make timing unreliable).
- `core.fsmonitor` hook round-trip (M2/M3, once it ships).
- IPC throughput (M2, once `TransportKit` lands).
- Diff viewer warm vs cold render (M3, once the diff parser + viewer exist).

## Profiling

When a regression shows up:

- **macOS** — Instruments. Time Profiler for CPU; Allocations for RAM; System Trace for file descriptors and kqueue events. Sprig's bundle ID = `com.sprig.app` (TBD; depends on brand availability).
- **Linux** — `perf record` / `perf report` for CPU; `heaptrack` for RAM; `strace -f -c` for syscall tally.
- **Windows** — Windows Performance Toolkit (WPA / WPR) for CPU + ETW; Visual Studio diagnostics for managed-heap-style allocations (less directly applicable to Swift but useful for the C++/COM shell extension when it lands).

A small `script/profile` helper lands alongside the first benchmark; it picks the right profiler per host OS and runs Sprig under it for a configurable duration.

## Known perf gotchas

- **`FileManager.default.contentsOfDirectory` includes hidden files by default.** Pass `[.skipsHiddenFiles]` for any tree walk that doesn't need them — saves a meaningful fraction of the snapshot time on directories with many `.DS_Store`-like files.
- **`URL.resourceValues(forKeys:)` calls into Foundation per file.** Cheap individually, expensive at 100k. Future optimization: bulk `stat(2)` via `posix_spawn` (POSIX) or `NtQueryDirectoryFile` (Windows) for the polling watcher's hot path.
- **`Data` allocations in parsers.** Each NUL-separated record allocates. Pre-sizing helps; `Data.reserveCapacity` is already used in `CatFileBatch.readExactly`. Future improvement: a slicing-only path that avoids copying for hot-path callers (the agent doesn't need to retain parser output after pushing into `RepoState`).
- **Sendable-wrapping `OpaquePointer`s** (FSEvents, future ReadDirectoryChangesW handles). Cheap at runtime but cluttering for readers; documented in the relevant `Sources/Mac/` and `Sources/Windows/` files.

## CI integration

The benchmark workflow (`.github/workflows/benchmarks.yml`) runs nightly on a self-hosted macOS-arm64 runner. It posts results to a `benchmarks/` branch as JMH-format JSON; trend visualization is community-tooling-pluggable (e.g. https://github.com/orgs/community/discussions/27474 patterns). Threshold-based regression detection blocks merge in the workflow; rolling-baseline detection happens out-of-band.

The hosted GitHub runners are explicitly *not* used for perf gates — they vary by ~3× CPU between back-to-back runs. They're fine for "did the benchmark binary build" smoke testing, which the regular CI runs do.
