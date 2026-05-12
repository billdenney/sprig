// ReadDirectoryChangesWatcherTests — exercise the Windows-native
// reactive watcher. Wrapped in `#if os(Windows)` because the
// implementation is Windows-only; the file is empty on macOS / Linux
// builds.
//
// Mirrors the shape of `PollingFileWatcherTests.PollingFileWatcherRealFSTests`
// (create / modify / remove + lifecycle). Each test calls
// `await watcher.awaitReady()` between `start()` and the mutation
// so the kernel notification is guaranteed live before the change
// fires — no time-based pre-write sleep.

#if os(Windows)
    import Foundation
    import PlatformKit
    import Testing
    @testable import WatcherKit

    @Suite("ReadDirectoryChangesWatcher end-to-end on real filesystem")
    struct ReadDirectoryChangesWatcherTests {
        private func makeTempDir(_ label: String) throws -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sprig-rdc-\(label)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        /// Collect events from the stream until `predicate` is
        /// satisfied OR `timeout` elapses. Returns whatever's
        /// accumulated. Mirrors the polling-watcher test helper.
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

        /// Maximum wait for the predicate to match. The collector
        /// exits the moment an event arrives, so happy-path tests
        /// finish in milliseconds; this ceiling only fires when
        /// something is genuinely slow.
        ///
        /// 10s headroom because `FILE_NOTIFY_CHANGE_LAST_WRITE` and
        /// `FILE_NOTIFY_CHANGE_SIZE` notifications are delayed until
        /// the kernel flushes the write cache (Microsoft's
        /// `ReadDirectoryChangesW` docs note this explicitly).
        /// `FILE_NOTIFY_CHANGE_FILE_NAME` events (create / remove /
        /// rename) fire immediately, so only `modifyDetected` is
        /// structurally exposed to the cache-flush delay — but the
        /// ceiling applies uniformly so all tests share one
        /// configuration knob.
        private static let eventTimeoutSec: Double = 10.0

        @Test("creating a file produces a .created event")
        func createDetected() async throws {
            let root = try makeTempDir("create")
            defer { try? FileManager.default.removeItem(at: root) }

            let watcher = ReadDirectoryChangesWatcher()
            let stream = watcher.start(paths: [root])
            await watcher.awaitReady()
            try Data("hi\n".utf8).write(to: root.appendingPathComponent("hello.txt"))

            let events = await collect(
                from: stream,
                until: { evs in evs.contains(where: { $0.kind == .created }) },
                timeout: Self.eventTimeoutSec
            )
            await watcher.stop()
            #expect(events.contains(where: {
                $0.kind == .created && $0.path.lastPathComponent == "hello.txt"
            }))
        }

        @Test("modifying a file produces some event for that file")
        func modifyDetected() async throws {
            let root = try makeTempDir("modify")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("a.txt")
            try Data("one\n".utf8).write(to: file)

            let watcher = ReadDirectoryChangesWatcher()
            let stream = watcher.start(paths: [root])
            await watcher.awaitReady()
            try Data("one\ntwo\n".utf8).write(to: file)

            // Predicate matches *any* event for `a.txt`, not just
            // `.modified`. `Foundation.Data.write(to:)` without
            // `.atomic` opens with `CREATE_ALWAYS` on Windows, which
            // truncates the existing file — the kernel may emit
            // `FILE_ACTION_ADDED` (for the truncated recreate) or
            // `FILE_ACTION_MODIFIED` (for the subsequent write)
            // depending on driver state. Both are correct signal
            // from the watcher's perspective: "something changed
            // for this file." Consumers (badges, RepoAgent's
            // coalescer) re-stat on every event regardless of kind.
            let events = await collect(
                from: stream,
                until: { evs in evs.contains(where: {
                    $0.path.lastPathComponent == "a.txt"
                }) },
                timeout: Self.eventTimeoutSec
            )
            await watcher.stop()
            #expect(events.contains(where: { $0.path.lastPathComponent == "a.txt" }))
        }

        @Test("deleting a file produces a .removed event")
        func removeDetected() async throws {
            let root = try makeTempDir("remove")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("doomed.txt")
            try Data("bye\n".utf8).write(to: file)

            let watcher = ReadDirectoryChangesWatcher()
            let stream = watcher.start(paths: [root])
            await watcher.awaitReady()
            try FileManager.default.removeItem(at: file)

            let events = await collect(
                from: stream,
                until: { evs in evs.contains(where: { $0.kind == .removed }) },
                timeout: Self.eventTimeoutSec
            )
            await watcher.stop()
            #expect(events.contains(where: {
                $0.kind == .removed && $0.path.lastPathComponent == "doomed.txt"
            }))
        }

        @Test("nested file under bWatchSubtree=true is observed")
        func nestedFileDetected() async throws {
            let root = try makeTempDir("nested")
            defer { try? FileManager.default.removeItem(at: root) }
            let subdir = root.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

            let watcher = ReadDirectoryChangesWatcher()
            let stream = watcher.start(paths: [root])
            await watcher.awaitReady()
            try Data("nested\n".utf8).write(to: subdir.appendingPathComponent("deep.txt"))

            let events = await collect(
                from: stream,
                until: { evs in evs.contains(where: { $0.path.lastPathComponent == "deep.txt" }) },
                timeout: Self.eventTimeoutSec
            )
            await watcher.stop()
            #expect(events.contains(where: { $0.path.lastPathComponent == "deep.txt" }))
        }

        @Test("stop() finishes the stream so for-await terminates")
        func stopFinishesStream() async throws {
            let root = try makeTempDir("stop")
            defer { try? FileManager.default.removeItem(at: root) }

            let watcher = ReadDirectoryChangesWatcher()
            let stream = watcher.start(paths: [root])

            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                await watcher.stop()
            }

            var seen = 0
            for await _ in stream {
                seen += 1
                if seen > 100 { break } // safety net; stop() should terminate the stream first
            }
            // No assertion on count — what we're testing is that
            // the for-await loop EXITS (otherwise the test would
            // hang and the suite would time out).
            #expect(seen <= 100)
        }
    }
#endif
