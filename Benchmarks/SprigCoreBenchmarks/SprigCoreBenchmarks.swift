// First-cut benchmarks for the Sprig portable core. Wires up
// ordo-one/package-benchmark against pure-Swift hot paths so we can detect
// regressions before they reach the watcher / agent.
//
// Coverage today
// --------------
// In-memory benchmarks (no filesystem, stable on hosted CI):
//   - PorcelainV2Parser.parse  @ 1k / 10k / 100k entries
//   - LogParser.parse          @ 1k / 10k commits
//   - EventCoalescer           @ 1k / 10k events ingest→drain
//
// Filesystem benchmarks (synthesize a temp tree once at suite registration,
// teardown via process exit; tmpfs is fine on Linux CI):
//   - PollingFileWatcher.takeSnapshot @ 1k / 10k / 100k file tree
//
// Pending: end-to-end `sprigctl status` (needs a synthesized git repo +
// process spawn — moves to a follow-up PR).
//
// Reference: docs/architecture/performance.md, ADR 0021.

import Benchmark
import Foundation
import GitCore
import PlatformKit
import WatcherKit

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
    logParserBenchmarks()
    eventCoalescerBenchmarks()
    pollingFileWatcherBenchmarks()
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

// MARK: - LogParser

/// Builds a NUL-terminated buffer of `commitCount` synthesized log entries
/// matching `LogParser.formatString`. Fields are separated by U+001F (Unit
/// Separator) and each entry is NUL-terminated, exactly as `git log -z
/// --format=...` emits.
private func makeLogBuffer(commitCount: Int) -> Data {
    var data = Data()
    let unitSeparator = "\u{1F}"
    // Stable ISO-8601 timestamps so the parser's date-parsing path is
    // exercised consistently across iterations.
    let authorDate = "2026-04-26T12:00:00+00:00"
    let committerDate = "2026-04-26T12:00:01+00:00"
    let authorName = "Sprig Bench"
    let authorEmail = "bench@sprig.app"
    let body = "Body line 1\nBody line 2\nBody line 3\n"

    for index in 0 ..< commitCount {
        let sha = String(format: "%040x", index)
        // Mix in some merge commits (every 7th) so the parents-split path
        // sees both 1-parent and 2-parent forms.
        let parents = if index > 0, index % 7 == 0 {
            "\(String(format: "%040x", index - 1)) \(String(format: "%040x", index - 2))"
        } else if index > 0 {
            String(format: "%040x", index - 1)
        } else {
            ""
        }
        let subject = "Commit subject for index \(index)"
        let fields: [String] = [
            sha, parents, authorDate, committerDate,
            authorName, authorEmail, authorName, authorEmail,
            subject, body
        ]
        data.append(fields.joined(separator: unitSeparator).data(using: .utf8)!)
        data.append(0)
    }
    return data
}

private func logParserBenchmarks() {
    for commitCount in [1000, 10000] {
        let buffer = makeLogBuffer(commitCount: commitCount)
        Benchmark("LogParser.parse — \(commitCount) commits") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try? LogParser.parse(buffer))
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

// MARK: - PollingFileWatcher.takeSnapshot

/// Synthesizes a directory tree of `fileCount` empty files, fanned out into
/// `dirsPerLevel`-wide directories so the walk traverses both deep and
/// broad. Returns the root URL; tree is cleaned up at process exit (the
/// benchmarking process spawns once per `swift package benchmark` run).
private func synthesizeTree(fileCount: Int, dirsPerLevel: Int = 32) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sprig-bench-tree-\(fileCount)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Two-level directory layout: dirsPerLevel × dirsPerLevel × N files
    // distributes 100k files across ~1000 leaf dirs (~100 files each),
    // similar to a real-world repo shape.
    let filesPerLeaf = max(1, fileCount / (dirsPerLevel * dirsPerLevel))
    var written = 0
    outer: for outerIndex in 0 ..< dirsPerLevel {
        for innerIndex in 0 ..< dirsPerLevel {
            let dir = root
                .appendingPathComponent("d\(outerIndex)")
                .appendingPathComponent("d\(innerIndex)")
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for fileIndex in 0 ..< filesPerLeaf {
                let file = dir.appendingPathComponent("f\(fileIndex).txt")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                written += 1
                if written >= fileCount { break outer }
            }
        }
    }
    return root
}

private func pollingFileWatcherBenchmarks() {
    for fileCount in [1000, 10000, 100_000] {
        let root = synthesizeTree(fileCount: fileCount)
        Benchmark("PollingFileWatcher.takeSnapshot — \(fileCount) files") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(PollingFileWatcher.takeSnapshot(of: [root]))
            }
        }
    }
}
