// WatcherEventBudgetTests.swift
//
// M1 → M2 exit gate (iii): the watcher must stay under 2% CPU on a
// hosted runner while ingesting 10k synthetic WatchEvents.
//
// CPU% isn't directly assertable from inside a swift-testing test
// (no clean way to read /proc/self/stat or its macOS / Windows
// equivalents portably). The honest proxy is **wall-clock time on a
// single-core synthetic load**: if EventCoalescer can ingest + drain
// 10k events in well under one wall-clock second on hosted-CI
// hardware, the steady-state CPU on a real watcher (which sees a few
// hundred events per second at most under user load) is comfortably
// below the ADR 0021 budget.
//
// The budget below is intentionally generous — Windows filesystem
// scheduling + Linux Foundation flake (catalog F1) can push individual
// runs up by an order of magnitude without indicating a real watcher
// regression. The assertion catches structural regressions (an O(N²)
// loop on path lookup, allocation per event, etc.), not jitter.

import Foundation
import PlatformKit
import Testing

@Suite("M1 → M2 gate: watcher event-budget under 10k synthetic events")
struct WatcherEventBudgetTests {
    /// Total events fed through the coalescer per assertion.
    private static let eventCount = 10000

    /// How many distinct paths to fan events across. With 10k events
    /// across 200 paths, the coalescer sees ~50 dupes per path —
    /// exercising the priority-weighted dedupe code path that's the
    /// hottest line in `EventCoalescer.ingest(_:)`.
    private static let pathPoolSize = 200

    /// Ceiling for the full ingest + drain pass at 10k events on a
    /// hosted CI runner.
    ///
    /// 3 s on every platform. Typical local measurement is ~200 ms,
    /// so this is a ~15× margin — deliberately generous because this
    /// is a *structural-regression* proxy (an O(N²) path lookup or a
    /// per-event allocation would blow it by orders of magnitude),
    /// NOT a precise perf gate. Under full-suite load on a shared
    /// hosted runner the same ~200 ms of CPU work has measured well
    /// over 1 s — PR #107/#108's Windows CI saw 1.028 s / 1.32 s on a
    /// 1 s budget (Windows was bumped to 3 s then), and a macos-15 run
    /// hit 1.237 s on the 1 s macOS/Linux budget. The platform split
    /// bought nothing — runner contention, not OS, is the variable —
    /// so the budget is unified at the Windows value. Pure CPU work
    /// isn't 3× slower in steady state on any platform, so persistent
    /// failures still surface real coalescer regressions.
    private static let wallClockBudget: Duration = .milliseconds(3000)

    @Test("EventCoalescer ingests + drains 10k synthetic events inside the wall-clock budget")
    func ingestAndDrainBudget() {
        let events = Self.makeEvents(count: Self.eventCount, pathPoolSize: Self.pathPoolSize)
        var coalescer = EventCoalescer()

        let start = ContinuousClock.now
        coalescer.ingest(events)
        let drained = coalescer.drain(upTo: Date().addingTimeInterval(60))
        let elapsed = ContinuousClock.now - start

        // Drain output is deduped per path; 200 distinct paths in,
        // 200 entries out. If this doesn't match, the test is buggy
        // (the budget assertion below would also have been
        // meaningless on a bad coalescer).
        #expect(
            drained.count == Self.pathPoolSize,
            "expected one drained entry per pooled path; got \(drained.count)"
        )

        #expect(
            elapsed < Self.wallClockBudget,
            "10k-event ingest+drain took \(elapsed); budget is \(Self.wallClockBudget)"
        )
    }

    @Test("EventCoalescer drains incremental ticks under the per-tick budget")
    func incrementalTickBudget() {
        // Closer to real-watcher cadence: drain on a sliding window so
        // the buffer stays small per tick. 10 ticks × 1000 events each.
        var coalescer = EventCoalescer()
        let perTick = 1000
        let tickCount = Self.eventCount / perTick

        let start = ContinuousClock.now
        for tickIndex in 0 ..< tickCount {
            let tickEvents = Self.makeEvents(
                count: perTick,
                pathPoolSize: Self.pathPoolSize,
                pathOffset: tickIndex * Self.pathPoolSize
            )
            coalescer.ingest(tickEvents)
            // Drain everything older than "now + 60 s" — i.e. drain
            // everything we just ingested. Real watcher ticks drain
            // older-than-window, but for budget the cutoff timing
            // doesn't matter; we want the full drain cost.
            _ = coalescer.drain(upTo: Date().addingTimeInterval(60))
        }
        let elapsed = ContinuousClock.now - start

        #expect(
            elapsed < Self.wallClockBudget,
            "\(tickCount)-tick × \(perTick) events drained in \(elapsed); budget is \(Self.wallClockBudget)"
        )
    }

    // MARK: - Synthetic event generator

    /// Build `count` events distributed across `pathPoolSize` distinct
    /// paths, cycling through every `WatchEventKind` so the dedupe /
    /// priority code is exercised across the whole enum.
    private static func makeEvents(
        count: Int,
        pathPoolSize: Int,
        pathOffset: Int = 0
    ) -> [WatchEvent] {
        let kinds = WatchEventKind.allCases.filter { $0 != .overflow }
        let baseTimestamp = Date(timeIntervalSinceReferenceDate: 0)
        var events: [WatchEvent] = []
        events.reserveCapacity(count)
        for index in 0 ..< count {
            let pathIndex = (index + pathOffset) % pathPoolSize
            let url = URL(fileURLWithPath: "/tmp/sprig-watcher-event-budget/p\(pathIndex)")
            let kind = kinds[index % kinds.count]
            // Monotonic timestamps so the priority-tie-break logic
            // ("newer at same priority wins") sees a non-degenerate
            // distribution. One-millisecond increments stay inside a
            // single `Date` precision.
            let ts = baseTimestamp.addingTimeInterval(Double(index) / 1000.0)
            events.append(WatchEvent(path: url, kind: kind, timestamp: ts))
        }
        return events
    }
}
