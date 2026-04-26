// First-cut benchmarks for the Sprig portable core. Wires up
// ordo-one/package-benchmark against pure-Swift hot paths so we can detect
// regressions before they reach the watcher / agent.
//
// Why these benchmarks first
// --------------------------
// Both targets here run on synthesized in-memory data — no temp directories,
// no real git, no FSEvents — so they're stable on hosted CI runners and on
// developer laptops. Filesystem-bound benchmarks (PollingFileWatcher tree
// walks, end-to-end `sprigctl status`) will land in a follow-up PR with a
// shared synthesized-repo helper.
//
// Reference: docs/architecture/performance.md, ADR 0021.

import Benchmark
import Foundation
import GitCore
import PlatformKit

/// Reasonable default config: capture wall-clock + CPU + allocations + peak
/// RSS, run for at most 1 s per scale, and sample 10 iterations. The numbers
/// move with hardware so we don't bake absolute thresholds into the
/// benchmark itself — regressions surface via the nightly baseline-compare
/// workflow, not this file (see docs/ci/self-hosted.md).
let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = Benchmark.Configuration(
        metrics: [.wallClock, .cpuTotal, .mallocCountTotal, .peakMemoryResident],
        timeUnits: .microseconds,
        maxDuration: .seconds(1),
        maxIterations: 10
    )

    porcelainV2Benchmarks()
    eventCoalescerBenchmarks()
}

// MARK: - PorcelainV2Parser

/// Builds a NUL-terminated porcelain-v2 buffer with `entryCount` "ordinary"
/// modified-file records plus the typical branch headers — same shape git
/// emits in a busy working tree.
private func makePorcelainV2Buffer(entryCount: Int) -> Data {
    var data = Data()

    func append(_ record: String) {
        data.append(record.data(using: .utf8)!)
        data.append(0)
    }

    let oid = String(repeating: "a", count: 40)
    append("# branch.oid \(oid)")
    append("# branch.head main")
    append("# branch.upstream origin/main")
    append("# branch.ab +0 -0")

    let hashA = String(repeating: "1", count: 40)
    let hashB = String(repeating: "2", count: 40)
    for index in 0 ..< entryCount {
        // Form: "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>"
        // .M (worktree-modified) ordinary record.
        append("1 .M N... 100644 100644 100644 \(hashA) \(hashB) src/file_\(index).swift")
    }
    return data
}

private func porcelainV2Benchmarks() {
    for entryCount in [1000, 10000, 100_000] {
        let buffer = makePorcelainV2Buffer(entryCount: entryCount)
        Benchmark("PorcelainV2Parser.parse — \(entryCount) entries") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try? PorcelainV2Parser.parse(buffer))
            }
        }
    }
}

// MARK: - EventCoalescer

/// Builds `count` watch events, alternating modified/created kinds across
/// `pathPoolSize` distinct paths so the coalescer sees realistic path-reuse
/// patterns (a few files modified many times, not all unique).
private func makeWatchEvents(count: Int, pathPoolSize: Int) -> [WatchEvent] {
    var events: [WatchEvent] = []
    events.reserveCapacity(count)
    let kinds: [WatchEventKind] = [.modified, .created, .modified, .modified]
    let now = Date()
    for index in 0 ..< count {
        let pathIndex = index % pathPoolSize
        let url = URL(fileURLWithPath: "/tmp/sprig-bench/file_\(pathIndex).swift")
        let kind = kinds[index % kinds.count]
        events.append(WatchEvent(
            path: url,
            kind: kind,
            timestamp: now.addingTimeInterval(Double(index) * 0.0001)
        ))
    }
    return events
}

private func eventCoalescerBenchmarks() {
    for eventCount in [1000, 10000] {
        // Pool size = 10% of event count → ~10× duplication per path,
        // representative of an editor-save burst pattern.
        let events = makeWatchEvents(count: eventCount, pathPoolSize: max(1, eventCount / 10))
        let cutoff = Date().addingTimeInterval(60)

        Benchmark("EventCoalescer.ingest+drain — \(eventCount) events") { benchmark in
            for _ in benchmark.scaledIterations {
                var coalescer = EventCoalescer()
                coalescer.ingest(events)
                blackHole(coalescer.drain(upTo: cutoff))
            }
        }
    }
}
