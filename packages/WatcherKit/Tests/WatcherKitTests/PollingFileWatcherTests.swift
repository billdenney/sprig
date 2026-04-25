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

    @Test("creating a file produces a .created event")
    func createDetected() async throws {
        let root = try makeTempDir("create")
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = PollingFileWatcher(pollInterval: 0.05)
        let stream = watcher.start(paths: [root])

        // Allow the initial snapshot to settle, then introduce a file.
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try? Data("hi\n".utf8).write(to: root.appendingPathComponent("hello.txt"))
        }

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .created }) },
            timeout: 3.0
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
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? Data("one\ntwo\n".utf8).write(to: file)
        }

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .modified }) },
            timeout: 3.0
        )
        await watcher.stop()
        #expect(events.contains(where: { $0.kind == .modified && $0.path.lastPathComponent == "a.txt" }))
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
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? FileManager.default.removeItem(at: file)
        }

        let events = await collect(
            from: stream,
            until: { evs in evs.contains(where: { $0.kind == .removed }) },
            timeout: 3.0
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
