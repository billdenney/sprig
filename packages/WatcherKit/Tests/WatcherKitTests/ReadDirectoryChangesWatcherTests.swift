// ReadDirectoryChangesWatcherTests — exercise the Windows-native
// reactive watcher. Wrapped in `#if os(Windows)` because the
// implementation is Windows-only; the file is empty on macOS / Linux
// builds.
//
// Mirrors the shape of `PollingFileWatcherTests.PollingFileWatcherRealFSTests`
// (create / modify / remove + lifecycle) but with tight timeouts —
// `ReadDirectoryChangesW` is reactive, so events should land well
// under a second.

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

        /// Brief delay between `start()` and the file mutation. The
        /// watcher's per-handle Task spawns synchronously inside
        /// `start()`, but the `ReadDirectoryChangesW` call itself
        /// runs on a dispatch thread that takes a few ms to issue
        /// the first I/O. 100ms is comfortable.
        private static let preWriteDelayNs: UInt64 = 100_000_000

        /// Reactive watcher — events arrive when the kernel emits
        /// them, not on a poll tick. 2s is plenty for hosted Windows
        /// runners; the predicate-driven `collect` exits the moment
        /// the event arrives so happy paths complete in
        /// milliseconds.
        private static let eventTimeoutSec: Double = 2.0

        @Test("creating a file produces a .created event")
        func createDetected() async throws {
            let root = try makeTempDir("create")
            defer { try? FileManager.default.removeItem(at: root) }

            let watcher = ReadDirectoryChangesWatcher()
            let stream = watcher.start(paths: [root])

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
            #expect(events.contains(where: {
                $0.kind == .created && $0.path.lastPathComponent == "hello.txt"
            }))
        }

        @Test("modifying a file produces a .modified event")
        func modifyDetected() async throws {
            let root = try makeTempDir("modify")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("a.txt")
            try Data("one\n".utf8).write(to: file)

            let watcher = ReadDirectoryChangesWatcher()
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
            #expect(events.contains(where: {
                $0.kind == .modified && $0.path.lastPathComponent == "a.txt"
            }))
        }

        @Test("deleting a file produces a .removed event")
        func removeDetected() async throws {
            let root = try makeTempDir("remove")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("doomed.txt")
            try Data("bye\n".utf8).write(to: file)

            let watcher = ReadDirectoryChangesWatcher()
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

            Task {
                try? await Task.sleep(nanoseconds: Self.preWriteDelayNs)
                try? Data("nested\n".utf8).write(to: subdir.appendingPathComponent("deep.txt"))
            }

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
