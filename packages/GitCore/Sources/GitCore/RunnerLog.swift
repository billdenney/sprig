// RunnerLog.swift
//
// Bounded ring buffer of completed `git` invocations + a fan-out
// AsyncStream so subscribers (the agent's IPC dispatch layer, ADR
// 0057's "Commands" panel UI) get live updates as commands complete.
//
// Per ADR 0057, every `Runner.run` invocation appends a
// ``LoggedCommand`` to a configured log; the agent exposes the log
// over IPC so task windows render the literal `git ...` Sprig issued.
//
// Tier-1 portable. Actor-isolated for cross-task safety. AsyncStream
// is the natural shape for live updates — it integrates with
// structured concurrency (`for await ...`) and cancels cleanly when
// the consuming task ends.
//
// **Capacity / overflow.** The ring buffer is bounded (default 256
// entries) so a long-running agent doesn't accumulate memory. When
// new entries push the buffer over capacity, oldest entries drop off
// the front. The AsyncStream itself does not buffer — subscribers
// that lag receive only entries from when they subscribed forward.
// (The "give me the last N" snapshot via ``entries()`` is the right
// shape for "panel just opened, render history.")

import Foundation

/// Bounded log of recent `git` invocations + a live event stream.
/// Constructed once per agent (typically); shared across multiple
/// `Runner` instances so a single `sprigctl status` or Commands
/// panel sees the union of all repos' commands.
public actor RunnerLog {
    /// Maximum number of entries retained in the ring buffer. When
    /// exceeded, oldest entries drop off the front of ``entries()``.
    public let capacity: Int

    /// Ring buffer. Insertion at the end; trim from the front when
    /// `count > capacity`.
    private var buffer: [LoggedCommand] = []

    /// Live subscribers. Each subscriber gets every record that
    /// arrives after their subscription. Unsubscribed by the
    /// AsyncStream's natural lifecycle (`onTermination`).
    private var subscribers: [UUID: AsyncStream<LoggedCommand>.Continuation] = [:]

    public init(capacity: Int = 256) {
        precondition(capacity > 0, "RunnerLog capacity must be > 0")
        self.capacity = capacity
    }

    // MARK: record

    /// Append `entry` to the buffer and yield it to every live
    /// subscriber. Trims the buffer if the insertion exceeds
    /// ``capacity``.
    public func record(_ entry: LoggedCommand) {
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for continuation in subscribers.values {
            continuation.yield(entry)
        }
    }

    // MARK: snapshot queries

    /// Snapshot of every entry currently in the ring buffer, oldest
    /// first.
    public func entries() -> [LoggedCommand] {
        buffer
    }

    /// Snapshot of entries whose ``LoggedCommand/startedAt`` is at or
    /// after `cutoff`. The Commands panel uses this when it opens to
    /// render "since this task window started" history without
    /// pulling commands from earlier sessions.
    public func entries(since cutoff: Date) -> [LoggedCommand] {
        buffer.filter { $0.startedAt >= cutoff }
    }

    /// Number of entries currently buffered. Diagnostic.
    public func count() -> Int {
        buffer.count
    }

    // MARK: live stream

    /// Subscribe to live updates. Yields every ``LoggedCommand``
    /// recorded after the subscription starts. The returned stream
    /// finishes when the actor's process ends or the consuming task
    /// is cancelled.
    ///
    /// **Backlog.** This stream does **not** replay buffered history.
    /// Call ``entries()`` (or ``entries(since:)``) once at subscription
    /// start to render history, then `for await` on this stream for
    /// new entries. The two snapshots may overlap by one entry near
    /// subscription time; subscribers dedupe by ``LoggedCommand/id``.
    public func events() -> AsyncStream<LoggedCommand> {
        AsyncStream<LoggedCommand> { continuation in
            let token = UUID()
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(token: token) }
            }
        }
    }

    private func unsubscribe(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    // MARK: lifecycle helpers

    /// Drop every buffered entry. Active subscribers continue
    /// receiving new entries; only the snapshot is reset.
    public func removeAll() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Diagnostic: how many subscribers are currently attached.
    public func subscriberCount() -> Int {
        subscribers.count
    }
}
