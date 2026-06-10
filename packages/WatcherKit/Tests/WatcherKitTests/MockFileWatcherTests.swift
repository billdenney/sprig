import Foundation
import PlatformKit
import Testing
@testable import WatcherKit

@Suite("MockFileWatcher")
struct MockFileWatcherTests {
    private func url(_ s: String) -> URL {
        URL(fileURLWithPath: s)
    }

    @Test("stream yields emitted events in order")
    func yieldsInOrder() async {
        let mock = MockFileWatcher()
        let stream = mock.start(paths: [url("/")])

        let events = [
            WatchEvent(path: url("/a"), kind: .created),
            WatchEvent(path: url("/b"), kind: .modified),
            WatchEvent(path: url("/c"), kind: .removed)
        ]

        // Emit in the background so the consumer can await the stream.
        Task {
            await mock.emit(many: events)
            await mock.stop()
        }

        var received: [WatchEvent] = []
        for await event in stream {
            received.append(event)
        }

        #expect(received.count == events.count)
        #expect(received.map(\.kind) == events.map(\.kind))
        #expect(received.map(\.path) == events.map(\.path))
    }

    @Test("emits queued before start get delivered once start is called")
    func queuedBeforeStart() async {
        let mock = MockFileWatcher()
        // Fire the emit FIRST (queued).
        await mock.emit(WatchEvent(path: url("/early"), kind: .created))

        let stream = mock.start(paths: [url("/")])
        Task { await mock.stop() }

        var received: [WatchEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received.map(\.path) == [url("/early")])
    }

    @Test("stop() finishes the stream so `for await` exits")
    func stopFinishesStream() async {
        let mock = MockFileWatcher()
        let stream = mock.start(paths: [url("/")])
        Task { await mock.stop() }

        var received: [WatchEvent] = []
        for await event in stream {
            received.append(event)
        }
        // If stop() didn't finish, we'd hang forever and the test would time out.
        #expect(received.isEmpty)
    }

    @Test("events flow through an EventCoalescer end-to-end")
    func integrationWithCoalescer() async {
        let mock = MockFileWatcher()
        let stream = mock.start(paths: [url("/")])
        var coalescer = EventCoalescer()

        let base = Date(timeIntervalSince1970: 1_000_000)
        Task {
            await mock.emit(many: [
                WatchEvent(path: url("/a"), kind: .modified, timestamp: base),
                WatchEvent(path: url("/a"), kind: .removed, timestamp: base.addingTimeInterval(0.01)),
                WatchEvent(path: url("/b"), kind: .created, timestamp: base.addingTimeInterval(0.02))
            ])
            await mock.stop()
        }

        for await event in stream {
            coalescer.ingest(event)
        }

        let drained = coalescer.drain(upTo: base.addingTimeInterval(10))
        #expect(drained.count == 2)
        // /a was dedup'd to .removed (higher priority than .modified)
        let byPath = Dictionary(uniqueKeysWithValues: drained.map { ($0.path, $0.kind) })
        #expect(byPath[url("/a")] == .removed)
        #expect(byPath[url("/b")] == .created)
    }

    @Test("stop racing the start-attach hop still terminates the stream (regression)")
    func stopBeforeAttachStillFinishes() async {
        // Regression for the stop-before-attach race: `start(paths:)`
        // attaches its continuation via an unstructured Task, so a
        // fast emit+stop can win the actor first. Pre-fix, the
        // nil-continuation finish was LOST and the consumer's
        // `for await` hung forever (the intermittent WatcherKitTests
        // full-suite hang). 500 iterations make the scheduling race
        // bite within the run if it ever regresses; each iteration
        // must both terminate AND deliver the pre-stop event.
        for _ in 0 ..< 500 {
            let mock = MockFileWatcher()
            let stream = mock.start(paths: [url("/")])
            await mock.emit(WatchEvent(path: url("/a"), kind: .created))
            await mock.stop()

            var received = 0
            for await _ in stream {
                received += 1
            }
            #expect(received == 1)
        }
    }
}
