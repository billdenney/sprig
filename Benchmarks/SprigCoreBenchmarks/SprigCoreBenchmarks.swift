// Benchmarks for the Sprig portable core. Wires up
// ordo-one/package-benchmark against pure-Swift hot paths and the
// end-to-end git invocation chain so we can detect regressions before
// they reach the watcher / agent.
//
// Coverage today
// --------------
// In-memory benchmarks (no filesystem, stable on hosted CI):
//   - PorcelainV2Parser.parse  @ 1k / 10k / 100k entries
//   - LogParser.parse          @ 1k / 10k commits
//   - EventCoalescer           @ 1k / 10k events ingest→drain
//
// Filesystem benchmarks (synthesize a temp tree once at suite registration):
//   - PollingFileWatcher.takeSnapshot @ 1k / 10k / 100k file tree
//
// End-to-end git benchmarks (synthesize a git repo with N tracked files
// and a 10% dirty fraction, then time the full status path):
//   - Runner.run + PorcelainV2Parser.parse @ 1k / 10k files
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
    statusEndToEndBenchmarks()
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

// MARK: - End-to-end: Runner.run + PorcelainV2Parser

/// Synthesizes a git repo with `fileCount` tracked files (committed),
/// then makes ~10 % of them worktree-dirty. Returns the repo URL.
///
/// **Synchronous on purpose.** Called at benchmark *registration* time
/// (outside any async context) so the repo is ready before
/// `scaledIterations` start, and so the synthesis cost isn't part of
/// the measured loop. Uses `Process` directly with the same race-safe
/// `terminationHandler` + `DispatchSemaphore` pattern that
/// `GitCore.ProcessTerminationGate` uses asynchronously.
///
/// Repo lives under `NSTemporaryDirectory()` and is left in place;
/// package-benchmark spawns one process per `swift package benchmark`
/// run, so OS cleanup happens at process exit.
private func runGitSync(_ args: [String], cwd: URL) {
    let process = Process()
    let gitPath = locateGit()
    process.executableURL = URL(fileURLWithPath: gitPath)
    process.arguments = args
    process.currentDirectoryURL = cwd
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    // Race-safe wait: same pattern as GitCore.ProcessTerminationGate,
    // but synchronous (DispatchSemaphore instead of async continuation).
    // Set terminationHandler BEFORE run() so we never miss the signal
    // when the child exits faster than Foundation's task-monitor setup.
    let sem = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in sem.signal() }
    do {
        try process.run()
    } catch {
        fatalError("benchmark setup: failed to spawn git \(args): \(error)")
    }
    sem.wait()
}

private func locateGit() -> String {
    let env = ProcessInfo.processInfo.environment
    let pathEnv = env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
    #if os(Windows)
        let exeName = "git.exe"
        let separator: Character = ";"
    #else
        let exeName = "git"
        let separator: Character = ":"
    #endif
    for dir in pathEnv.split(separator: separator).map(String.init) {
        let candidate = (dir as NSString).appendingPathComponent(exeName)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    fatalError("benchmark setup: git not found on PATH=\(pathEnv)")
}

private func synthesizeRepo(fileCount: Int) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sprig-bench-repo-\(fileCount)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Two-level fanout matching the polling-watcher benchmark, so the
    // tree shape is consistent and `git status` traversal cost is
    // representative.
    let dirsPerLevel = 32
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
                _ = FileManager.default.createFile(
                    atPath: file.path,
                    contents: Data("seed\(written)\n".utf8)
                )
                written += 1
                if written >= fileCount { break outer }
            }
        }
    }

    // Initial commit via direct sync git invocations.
    runGitSync(["init", "-b", "main"], cwd: root)
    runGitSync(["config", "user.email", "bench@sprig.app"], cwd: root)
    runGitSync(["config", "user.name", "Sprig Bench"], cwd: root)
    runGitSync(["config", "commit.gpgsign", "false"], cwd: root)
    runGitSync(["add", "-A"], cwd: root)
    runGitSync(["commit", "-m", "seed"], cwd: root)

    // Make ~10 % of files worktree-dirty so `git status` actually has
    // entries to report — matches the modify-some-files-then-status
    // pattern that drives Sprig's badge updates.
    let dirtyEvery = 10
    var dirtied = 0
    dirty: for outerIndex in 0 ..< dirsPerLevel {
        for innerIndex in 0 ..< dirsPerLevel {
            let dir = root
                .appendingPathComponent("d\(outerIndex)")
                .appendingPathComponent("d\(innerIndex)")
            for fileIndex in 0 ..< filesPerLeaf where dirtied % dirtyEvery == 0 {
                let file = dir.appendingPathComponent("f\(fileIndex).txt")
                if FileManager.default.fileExists(atPath: file.path) {
                    try! Data("dirty-\(dirtied)\n".utf8).write(to: file)
                }
                dirtied += 1
                if dirtied >= fileCount { break dirty }
            }
            if dirtied >= fileCount { break dirty }
        }
    }

    return root
}

private func statusEndToEndBenchmarks() {
    // 100k files would push setup time past 30 s on hosted CI; benchmark
    // for that scale lives on the self-hosted runner workflow and is
    // gated by ADR 0021 budgets.
    for fileCount in [1000, 10000] {
        // Synthesize at registration time, OUTSIDE the benchmark closure,
        // so the cost isn't attributed to the measured iterations.
        let repo = synthesizeRepo(fileCount: fileCount)
        Benchmark(
            "Runner.run + PorcelainV2Parser.parse — \(fileCount) files",
            configuration: Benchmark.Configuration(
                metrics: [.wallClock, .cpuTotal, .mallocCountTotal, .peakMemoryResident],
                timeUnits: .microseconds,
                // The git-status walk dominates here; cap iterations so
                // even 10k stays inside the per-bench budget.
                maxDuration: .seconds(2),
                maxIterations: 5
            )
        ) { benchmark in
            let runner = Runner(defaultWorkingDirectory: repo)
            for _ in benchmark.scaledIterations {
                let output = try await runner.run([
                    "status",
                    "--porcelain=v2",
                    "--branch",
                    "--show-stash",
                    "-z",
                    "--untracked-files=all"
                ])
                blackHole(try? PorcelainV2Parser.parse(output.stdout))
            }
        }
    }
}
