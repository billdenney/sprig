import Foundation
@testable import GitCore
import Testing

@Suite("RunnerLog — bounded ring buffer + live event stream")
struct RunnerLogTests {
    private func makeEntry(
        id: UUID = UUID(),
        argv: [String] = ["/usr/bin/git", "status"],
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        exitCode: Int32 = 0
    ) -> LoggedCommand {
        LoggedCommand(
            id: id,
            argv: argv,
            startedAt: startedAt,
            finishedAt: finishedAt ?? startedAt,
            exitCode: exitCode
        )
    }

    // MARK: empty + count

    @Test("a fresh log has zero entries and zero subscribers")
    func emptyOnInit() async {
        let log = RunnerLog()
        #expect(await log.count() == 0)
        #expect(await log.entries().isEmpty)
        #expect(await log.subscriberCount() == 0)
    }

    // MARK: record + snapshot

    @Test("record appends to entries() in order")
    func recordAppends() async {
        let log = RunnerLog()
        await log.record(makeEntry(argv: ["git", "a"]))
        await log.record(makeEntry(argv: ["git", "b"]))
        await log.record(makeEntry(argv: ["git", "c"]))
        let snap = await log.entries()
        #expect(snap.count == 3)
        #expect(snap.map(\.argv.last) == ["a", "b", "c"])
    }

    // MARK: capacity / ring-buffer trim

    @Test("buffer trims oldest entries when count exceeds capacity")
    func capacityTrim() async {
        let log = RunnerLog(capacity: 3)
        for index in 0 ..< 5 {
            await log.record(makeEntry(argv: ["git", "\(index)"]))
        }
        let snap = await log.entries()
        #expect(snap.count == 3)
        // Entries 0 and 1 fell off the front; 2/3/4 remain.
        #expect(snap.map(\.argv.last) == ["2", "3", "4"])
    }

    // MARK: since-cutoff filter

    @Test("entries(since:) filters to startedAt >= cutoff")
    func entriesSinceFilter() async {
        let log = RunnerLog()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_000_010)
        let t2 = Date(timeIntervalSince1970: 1_000_020)
        await log.record(makeEntry(startedAt: t0))
        await log.record(makeEntry(startedAt: t1))
        await log.record(makeEntry(startedAt: t2))

        // Cutoff between t0 and t1 — only t1 + t2 qualify.
        let cutoff = Date(timeIntervalSince1970: 1_000_005)
        let filtered = await log.entries(since: cutoff)
        #expect(filtered.count == 2)
        #expect(filtered.map(\.startedAt) == [t1, t2])
    }

    @Test("entries(since:) inclusive: cutoff equal to startedAt is included")
    func entriesSinceInclusive() async {
        let log = RunnerLog()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await log.record(makeEntry(startedAt: t0))
        let snap = await log.entries(since: t0)
        #expect(snap.count == 1)
    }

    // MARK: removeAll

    @Test("removeAll clears entries; subsequent record works")
    func removeAllClears() async {
        let log = RunnerLog()
        await log.record(makeEntry())
        await log.record(makeEntry())
        await log.removeAll()
        #expect(await log.count() == 0)
        await log.record(makeEntry())
        #expect(await log.count() == 1)
    }

    // MARK: live event stream

    @Test("a subscriber receives entries recorded after subscription")
    func subscriberReceivesPostSubscribe() async throws {
        let log = RunnerLog()
        let stream = await log.events()
        // Subscriber count goes up once the AsyncStream's body has run.
        // We read it via the count, then push entries.
        try await Task.sleep(nanoseconds: 5_000_000) // 5 ms — let stream init
        #expect(await log.subscriberCount() == 1)

        let recorderTask = Task {
            await log.record(makeEntry(argv: ["git", "post-sub"]))
        }
        await recorderTask.value

        var received: [LoggedCommand] = []
        for await entry in stream {
            received.append(entry)
            if received.count == 1 { break }
        }
        #expect(received.first?.argv.last == "post-sub")
    }

    @Test("a subscriber does NOT receive entries recorded before subscription (no replay)")
    func subscriberDoesNotReplayBacklog() async throws {
        let log = RunnerLog()
        // Record before subscribing.
        await log.record(makeEntry(argv: ["git", "old"]))

        let stream = await log.events()
        try await Task.sleep(nanoseconds: 5_000_000)
        await log.record(makeEntry(argv: ["git", "new"]))

        var received: [LoggedCommand] = []
        for await entry in stream {
            received.append(entry)
            if received.count == 1 { break }
        }
        // Only the post-subscription entry arrives.
        #expect(received.first?.argv.last == "new")
    }

    @Test("multiple subscribers each receive every entry recorded after they subscribed")
    func multipleSubscribers() async throws {
        let log = RunnerLog()
        let s1 = await log.events()
        try await Task.sleep(nanoseconds: 5_000_000)
        let s2 = await log.events()
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(await log.subscriberCount() == 2)

        await log.record(makeEntry(argv: ["git", "shared"]))

        async let received1: [LoggedCommand] = collect(stream: s1, count: 1)
        async let received2: [LoggedCommand] = collect(stream: s2, count: 1)
        let r1 = await received1
        let r2 = await received2
        #expect(r1.first?.argv.last == "shared")
        #expect(r2.first?.argv.last == "shared")
    }

    @Test("subscriber count drops when a stream's consuming task ends")
    func subscriberCountDrops() async throws {
        let log = RunnerLog()
        let task = Task {
            let stream = await log.events()
            try await Task.sleep(nanoseconds: 10_000_000)
            // Consume one entry, then exit.
            for await _ in stream {
                break
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await log.subscriberCount() == 1)

        await log.record(makeEntry())
        try await task.value

        // Allow a tick for the onTermination handler to run.
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await log.subscriberCount() == 0)
    }

    // MARK: helpers

    private func collect(stream: AsyncStream<LoggedCommand>, count want: Int) async -> [LoggedCommand] {
        var got: [LoggedCommand] = []
        for await entry in stream {
            got.append(entry)
            if got.count >= want { break }
        }
        return got
    }
}
