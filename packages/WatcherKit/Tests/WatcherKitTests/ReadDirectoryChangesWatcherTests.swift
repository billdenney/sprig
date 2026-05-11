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
        /// them, not on a poll tick. The predicate-driven `collect`
        /// exits the moment the event arrives so happy paths
        /// complete in milliseconds; the ceiling only matters when
        /// something is genuinely slow.
        ///
        /// 10s headroom (rather than 1–2s) because of a documented
        /// Windows quirk: `FILE_NOTIFY_CHANGE_LAST_WRITE` and
        /// `FILE_NOTIFY_CHANGE_SIZE` notifications are delayed until
        /// the kernel flushes the file's write cache. For small
        /// writes on a busy hosted runner, that flush can take
        /// several seconds. `FILE_NOTIFY_CHANGE_FILE_NAME` events
        /// (create / remove / rename) fire immediately, so the
        /// other tests in this suite typically complete in
        /// milliseconds; only `modifyDetected` is structurally
        /// vulnerable to the cache-flush delay. See
        /// `docs/architecture/cross-platform-quirks.md` (entry E1)
        /// and Microsoft's
        /// `ReadDirectoryChangesW` docs note on cache-flush
        /// behaviour.
        private static let eventTimeoutSec: Double = 10.0

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

        @Test("modifying a file produces some event for that file")
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

            // Predicate intentionally matches *any* event for
            // `a.txt`, not just `.modified`. Two Windows-specific
            // reasons:
            //
            // 1. `Foundation.Data.write(to:)` without `.atomic` opens
            //    with `CREATE_ALWAYS` on Windows, which truncates
            //    the existing file. The kernel may emit
            //    `FILE_ACTION_ADDED` (for the truncated recreate)
            //    OR `FILE_ACTION_MODIFIED` (for the subsequent
            //    write) depending on driver + buffering state. Both
            //    are correct from the watcher's perspective —
            //    "something changed for this file" is the signal
            //    consumers actually want.
            //
            // 2. The pure `.modified` predicate ran into another
            //    Windows quirk:
            //    `FILE_NOTIFY_CHANGE_LAST_WRITE`/`...CHANGE_SIZE`
            //    notifications are delayed until cache flush
            //    (Microsoft documents this on the
            //    `ReadDirectoryChangesW` API page). With the
            //    permissive predicate the test passes on whichever
            //    action the kernel happened to emit first.
            //
            // Pre-`.modified`-only predicate fixture flake: see CI
            // run 25689125187 / PR #89.
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
