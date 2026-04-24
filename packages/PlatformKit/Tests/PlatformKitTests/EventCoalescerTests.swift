import Foundation
@testable import PlatformKit
import Testing

@Suite("EventCoalescer")
struct EventCoalescerTests {
    // MARK: fixtures

    private func url(_ s: String) -> URL {
        URL(fileURLWithPath: s)
    }

    private func ev(
        _ path: String,
        _ kind: WatchEventKind,
        _ t: TimeInterval
    ) -> WatchEvent {
        WatchEvent(
            path: url(path),
            kind: kind,
            timestamp: Date(timeIntervalSince1970: t)
        )
    }

    // MARK: ingest

    @Test("ingest stores one event per path")
    func ingestOnePerPath() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .modified, 1))
        c.ingest(ev("/b", .modified, 1))
        c.ingest(ev("/a", .modified, 2)) // same path, newer
        #expect(c.count == 2)
    }

    @Test("ingest keeps the higher-priority kind when both fire for the same path")
    func ingestKeepsHigherPriority() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .modified, 1))
        c.ingest(ev("/a", .removed, 2)) // removed > modified
        let drained = c.drain(upTo: Date(timeIntervalSince1970: 10))
        #expect(drained.count == 1)
        #expect(drained.first?.kind == .removed)
    }

    @Test("ingest keeps newer timestamp when priorities tie")
    func ingestKeepsNewerOnTie() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .modified, 1))
        c.ingest(ev("/a", .modified, 3))
        let drained = c.drain(upTo: Date(timeIntervalSince1970: 10))
        #expect(drained.first?.timestamp == Date(timeIntervalSince1970: 3))
    }

    @Test("ingest does not downgrade kind when lower-priority event arrives later")
    func ingestDoesNotDowngrade() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .removed, 1))
        c.ingest(ev("/a", .modified, 2)) // modified < removed
        let drained = c.drain(upTo: Date(timeIntervalSince1970: 10))
        #expect(drained.first?.kind == .removed)
    }

    @Test("batch ingest processes all events")
    func batchIngest() {
        var c = EventCoalescer()
        c.ingest([
            ev("/a", .modified, 1),
            ev("/b", .created, 1),
            ev("/c", .removed, 1)
        ])
        #expect(c.count == 3)
    }

    // MARK: drain

    @Test("drain returns only events at or before cutoff")
    func drainWindow() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .modified, 1))
        c.ingest(ev("/b", .modified, 5))
        c.ingest(ev("/c", .modified, 10))
        let cutoff = Date(timeIntervalSince1970: 5)
        let drained = c.drain(upTo: cutoff)
        #expect(drained.count == 2)
        let paths = Set(drained.map(\.path.path))
        #expect(paths == [url("/a").path, url("/b").path])
        // /c stays buffered
        #expect(c.count == 1)
    }

    @Test("drain on empty coalescer returns empty array")
    func drainEmpty() {
        var c = EventCoalescer()
        let drained = c.drain(upTo: Date())
        #expect(drained.isEmpty)
    }

    @Test("drain removes the returned events so next drain returns nothing")
    func drainIsDestructive() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .modified, 1))
        _ = c.drain(upTo: Date(timeIntervalSince1970: 10))
        #expect(c.count == 0)
        #expect(c.drain(upTo: Date(timeIntervalSince1970: 100)).isEmpty)
    }

    // MARK: overflow semantics

    @Test("overflow drains all paths regardless of cutoff")
    func overflowForcesFullDrain() {
        var c = EventCoalescer()
        c.ingest(ev("/a", .modified, 1))
        c.ingest(ev("/b", .modified, 100)) // in the future
        c.ingest(ev("/?", .overflow, 50))
        #expect(c.overflowPending)

        let cutoff = Date(timeIntervalSince1970: 0) // earlier than every event
        let drained = c.drain(upTo: cutoff)
        // /a, /b, and the overflow sentinel all drain.
        #expect(drained.count == 3)
        #expect(!c.overflowPending)
    }

    @Test("overflow flag clears after drain so subsequent ticks are normal")
    func overflowFlagClears() {
        var c = EventCoalescer()
        c.ingest(ev("/?", .overflow, 1))
        _ = c.drain(upTo: Date(timeIntervalSince1970: 10))
        c.ingest(ev("/a", .modified, 5))
        let drained = c.drain(upTo: Date(timeIntervalSince1970: 3))
        #expect(drained.isEmpty) // /a is after cutoff; no overflow now
        #expect(c.count == 1)
    }
}
