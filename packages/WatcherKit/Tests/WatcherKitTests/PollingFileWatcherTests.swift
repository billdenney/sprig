import Foundation
import PlatformKit
import Testing
@testable import WatcherKit

@Suite("PollingFileWatcher diff (pure)")
struct PollingFileWatcherDiffTests {
    private func url(_ s: String) -> URL {
        URL(fileURLWithPath: s)
    }

    private func meta(_ size: UInt64, _ mtime: TimeInterval, isDir: Bool = false) -> FileMetadata {
        FileMetadata(size: size, mtime: Date(timeIntervalSince1970: mtime), isDir: isDir)
    }

    @Test("empty inputs produce no events")
    func emptyInputs() {
        let events = PollingFileWatcher.diff(old: [:], new: [:])
        #expect(events.isEmpty)
    }

    @Test("new path in `new` but not `old` is .created")
    func detectsCreated() {
        let events = PollingFileWatcher.diff(
            old: [:],
            new: [url("/a"): meta(10, 1)]
        )
        #expect(events.count == 1)
        #expect(events.first?.kind == .created)
        #expect(events.first?.path == url("/a"))
    }

    @Test("path in `old` but not `new` is .removed")
    func detectsRemoved() {
        let events = PollingFileWatcher.diff(
            old: [url("/a"): meta(10, 1)],
            new: [:]
        )
        #expect(events.first?.kind == .removed)
    }

    @Test("size change emits .modified")
    func detectsSizeChange() {
        let events = PollingFileWatcher.diff(
            old: [url("/a"): meta(10, 1)],
            new: [url("/a"): meta(20, 1)]
        )
        #expect(events.first?.kind == .modified)
    }

    @Test("mtime change emits .modified")
    func detectsMtimeChange() {
        let events = PollingFileWatcher.diff(
            old: [url("/a"): meta(10, 1)],
            new: [url("/a"): meta(10, 2)]
        )
        #expect(events.first?.kind == .modified)
    }

    @Test("identical snapshot produces no events")
    func noopWhenIdentical() {
        let snap = [url("/a"): meta(10, 1), url("/b"): meta(20, 2)]
        let events = PollingFileWatcher.diff(old: snap, new: snap)
        #expect(events.isEmpty)
    }

    @Test("multi-file diff covers create, modify, and remove together")
    func mixedDiff() {
        let old: [URL: FileMetadata] = [
            url("/keep"): meta(10, 1),
            url("/changed"): meta(10, 1),
            url("/gone"): meta(5, 1)
        ]
        let new: [URL: FileMetadata] = [
            url("/keep"): meta(10, 1),
            url("/changed"): meta(10, 2), // mtime bumped
            url("/added"): meta(7, 3)
        ]
        let events = PollingFileWatcher.diff(old: old, new: new)
        let byPath = Dictionary(uniqueKeysWithValues: events.map { ($0.path, $0.kind) })
        #expect(byPath[url("/changed")] == .modified)
        #expect(byPath[url("/added")] == .created)
        #expect(byPath[url("/gone")] == .removed)
        #expect(byPath[url("/keep")] == nil)
    }
}

/// PollingFileWatcher's live-FS suite is the *fallback*-path coverage
/// on Windows — production traffic goes through
/// `ReadDirectoryChangesWatcher` (added in PR #88). Windows hosted
/// runners under load have intermittent multi-second latency in
/// `FileManager.contentsOfDirectory`'s underlying `FindFirstFile` /
/// `FindNextFile`, which is structurally what the polling watcher
/// queries. That latency previously made this suite flaky on Windows,
/// so the suite was disabled there entirely.
///
/// **Re-enabled with per-platform budgets**: rather than tune one
/// budget across all three OSes (which left Windows with too little
/// margin while macOS / Linux paid for the headroom in suite time),
/// the pre-write delay and event timeout below are platform-
/// conditional. Windows gets ~5× the wall-clock budget to absorb its
/// worst-case `FindFirstFile` lag (the cross-platform-quirks catalog
/// documents up to ~2 s per filesystem op on hosted runners); macOS
/// and Linux keep their tight budgets so the suite still finishes in
/// ~1 s on those platforms.
///
/// This is one of the rare places we use `#if os(...)` in
/// portable-package source. CLAUDE.md's tier-1 rule bans behavioral
/// branching on `os()`; this is a test-only TIMING constant, not a
/// behavior branch (the same code paths run on every platform with
/// only the deadlines changing).
@Suite("PollingFileWatcher end-to-end on real filesystem")
struct PollingFileWatcherRealFSTests {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-polling-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Collect events from the stream until `predicate` is satisfied OR
    /// `timeout` elapses. Returns whatever has accumulated.
    private func collect(
        from stream: AsyncStream<WatchEvent>,
        until predicate: @Sendable @escaping ([WatchEvent]) -> Bool,
        timeout: TimeInterval
    ) async -> [WatchEvent] {
        await withTaskGroup(of: [WatchEvent].self) { group in
            group.addTask {
                var events: [WatchEvent] = []
                for await event in stream {
                    events.append(event)
                    if predicate(events) { break }
                }
                return events
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// Pre-write delay for the live-watcher tests below. The baseline
    /// snapshot is now captured SYNCHRONOUSLY inside `start()` (before the
    /// stream is returned), so the old baseline-vs-write race is gone and
    /// on macOS/Linux this delay is pure headroom. It is kept to absorb
    /// filesystem *write-visibility* lag — the window between a write
    /// returning and the next directory walk seeing it — which on Windows
    /// can be significant. (`immediateCreateAfterStartIsDetected` above
    /// deliberately omits this delay to pin the synchronous baseline.)
    ///
    /// Platform-conditional:
    /// - macOS / Linux: 500 ms is generous. Runners settle in ~30–50 ms,
    ///   so this is mostly headroom. Bumping past 500 ms only adds suite
    ///   time without catching anything new (main runs at 100 / 150 ms
    ///   under PRs #22 / #23 caught the snapshot-race; 500 ms ended it).
    /// - Windows: 2.5 s. Hosted Windows runner filesystem visibility can
    ///   lag up to ~2 s on the `FindFirstFile` / `FindNextFile` calls
    ///   that back `FileManager.contentsOfDirectory`
    ///   (`docs/architecture/cross-platform-quirks.md`). Giving the
    ///   initial snapshot 2.5 s before the test mutation absorbs that
    ///   worst case + the 50 ms poll interval with headroom.
    private static let preWriteDelayNs: UInt64 = {
        #if os(Windows)
            return 2_500_000_000
        #else
            return 500_000_000
        #endif
    }()

    /// Maximum wait for the polling watcher to surface an expected
    /// event. The `collect` helper exits as soon as the `until:`
    /// predicate matches, so wall-clock cost is the time-to-event, not
    /// this ceiling; the ceiling only matters when something's wrong.
    ///
    /// Platform-conditional:
    /// - macOS / Linux: 5 s. Events typically arrive in <100 ms; 5 s is
    ///   a generous backstop for hosted-runner load spikes.
    /// - Windows: 30 s. Worst-case is `preWriteDelayNs (2.5 s) + 2 s
    ///   FindFirstFile lag + poll interval (50 ms) ≈ 4.6 s`; 30 s leaves
    ///   ~6× headroom on top, which the disabled-tests.md notes were
    ///   needed to clear the recurring flake. Almost always returns
    ///   well before the ceiling because `collect`'s `until:` predicate
    ///   short-circuits on first match.
    private static let eventTimeoutSec: Double = {
        #if os(Windows)
            return 30.0
        #else
            return 5.0
        #endif
    }()

    @Test("creating a file produces a .created event")
    func createDetected() async throws {
        let root = try makeTempDir("create")
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = PollingFileWatcher(pollInterval: 0.05)
        let stream = watcher.start(paths: [root])

        // Allow the initial snapshot to settle, then introduce a file.
        Task {
            try? await Task.sleep(nanoseconds: Self.preWriteDelayNs)
            try? Data("hi\n".utf8).write(to: root.appendingPathComponent("hello.txt"))
        }

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .created }) },
            timeout: Self.eventTimeoutSec
        )
        await watcher.stop()
        #expect(events.contains(where: { $0.kind == .created && $0.path.lastPathComponent == "hello.txt" }))
    }

    @Test("modifying a file produces a .modified event")
    func modifyDetected() async throws {
        let root = try makeTempDir("modify")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data("one\n".utf8).write(to: file)

        let watcher = PollingFileWatcher(pollInterval: 0.05)
        let stream = watcher.start(paths: [root])

        Task {
            try? await Task.sleep(nanoseconds: Self.preWriteDelayNs)
            try? Data("one\ntwo\n".utf8).write(to: file)
        }

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .modified }) },
            timeout: Self.eventTimeoutSec
        )
        await watcher.stop()
        #expect(events.contains(where: { $0.kind == .modified && $0.path.lastPathComponent == "a.txt" }))
    }

    @Test("a file created immediately after start() — no settle delay — is detected (synchronous baseline)")
    func immediateCreateAfterStartIsDetected() async throws {
        // Regression guard for the baseline race. `start()` now captures
        // its baseline SYNCHRONOUSLY (before returning the stream), so a
        // change made the instant start() returns — with NO preWriteDelay,
        // deliberately — is still diffed. Before the fix the baseline was
        // taken as the first line of the polling Task and, under scheduler
        // pressure, could run AFTER this write and silently fold it into
        // the baseline; that surfaced as a flaky agent end-to-end test
        // where the badge never arrived under load. The missing delay here
        // is the whole point: it pins the race window shut.
        let root = try makeTempDir("immediate")
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = PollingFileWatcher(pollInterval: 0.05)
        let stream = watcher.start(paths: [root])
        try Data("hi\n".utf8).write(to: root.appendingPathComponent("new.txt"))

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .created }) },
            timeout: Self.eventTimeoutSec
        )
        await watcher.stop()
        #expect(events.contains(where: { $0.kind == .created && $0.path.lastPathComponent == "new.txt" }))
    }

    @Test("deleting a file produces a .removed event")
    func removeDetected() async throws {
        let root = try makeTempDir("remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("doomed.txt")
        try Data("bye\n".utf8).write(to: file)

        let watcher = PollingFileWatcher(pollInterval: 0.05)
        let stream = watcher.start(paths: [root])

        Task {
            try? await Task.sleep(nanoseconds: Self.preWriteDelayNs)
            try? FileManager.default.removeItem(at: file)
        }

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .removed }) },
            timeout: Self.eventTimeoutSec
        )
        await watcher.stop()
        #expect(events.contains(where: { $0.kind == .removed && $0.path.lastPathComponent == "doomed.txt" }))
    }

    @Test("stop() finishes the stream so for-await terminates")
    func stopFinishesStream() async throws {
        let root = try makeTempDir("stop")
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = PollingFileWatcher(pollInterval: 0.05)
        let stream = watcher.start(paths: [root])

        // Issue stop() concurrently. The for-await loop should exit cleanly.
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await watcher.stop()
        }

        var seen = 0
        for await _ in stream {
            seen += 1
            if seen > 100 { break } // safety net; stop() should kill the loop first
        }
        // No assertion on count — what we're testing is that the loop EXITS
        // (otherwise the test would hang and the suite would time out).
        #expect(seen <= 100)
    }
}
