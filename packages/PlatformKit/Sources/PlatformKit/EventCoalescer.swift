import Foundation

/// Collapses a bursty `WatchEvent` stream into one entry per path within a
/// time window.
///
/// Rationale
/// ---------
/// FSEvents, inotify, and ReadDirectoryChangesW all emit multiple events
/// when a single "user change" happens — an editor save often produces 2–4
/// events (create temp, rename, delete temp) inside a few milliseconds. The
/// Sprig watcher wants to hand RepoState a *set of paths that changed in
/// the last tick*, not the raw stream, so we can drive `git status` at the
/// tick rate rather than per event.
///
/// This type is a pure value — no timers, no threads. It's driven by the
/// caller feeding it events and ticks. That makes it trivial to unit-test
/// and deterministic under `Task.sleep`-free test suites.
///
/// Behavior
/// --------
/// - `ingest(_:)` records the event and upgrades the stored kind if the new
///   one is "more destructive" (see ``WatchEventKind.priority``). An
///   existing ``WatchEventKind/overflow`` stays overflow.
/// - `drain(upTo:)` returns and removes all events whose `timestamp` is at
///   or before the cutoff. Call this on each watcher tick with
///   `Date() - window`.
/// - An ``WatchEventKind/overflow`` event drains *all* paths regardless of
///   window, so a buffer-overflow signal always propagates immediately.
public struct EventCoalescer: Sendable {
    private var perPath: [URL: WatchEvent] = [:]
    private var hasOverflow = false

    public init() {}

    /// Number of distinct paths currently buffered.
    public var count: Int {
        perPath.count
    }

    /// Is an overflow event pending? (Tests use this.)
    public var overflowPending: Bool {
        hasOverflow
    }

    /// Record an incoming event. The stored event for a path is whichever of
    /// (existing, new) has higher ``WatchEventKind/priority``; ties keep the
    /// newer timestamp.
    public mutating func ingest(_ event: WatchEvent) {
        if event.kind == .overflow {
            hasOverflow = true
        }
        if let existing = perPath[event.path] {
            let newerAtSamePriority = event.kind.priority == existing.kind.priority
                && event.timestamp > existing.timestamp
            if event.kind.priority > existing.kind.priority {
                perPath[event.path] = event
            } else if newerAtSamePriority {
                perPath[event.path] = WatchEvent(
                    path: existing.path,
                    kind: existing.kind,
                    timestamp: event.timestamp
                )
            }
        } else {
            perPath[event.path] = event
        }
    }

    /// Batch convenience.
    public mutating func ingest(_ events: some Sequence<WatchEvent>) {
        for event in events {
            ingest(event)
        }
    }

    /// Remove and return all events whose `timestamp` is ≤ `cutoff`. If an
    /// overflow is pending, returns *all* stored events and clears the
    /// overflow flag.
    public mutating func drain(upTo cutoff: Date) -> [WatchEvent] {
        if hasOverflow {
            let all = Array(perPath.values)
            perPath.removeAll(keepingCapacity: true)
            hasOverflow = false
            return all
        }
        var ready: [WatchEvent] = []
        for (path, event) in perPath where event.timestamp <= cutoff {
            ready.append(event)
            perPath.removeValue(forKey: path)
        }
        return ready
    }
}

public extension WatchEventKind {
    /// Ordering used by ``EventCoalescer`` to decide which observation to
    /// keep when multiple events fire for the same path in a single window.
    ///
    /// overflow > removed > renamed > created > modified > unknown
    ///
    /// The rule of thumb: "more destructive" kinds win, because a consumer
    /// that only sees `modified` when the file was actually deleted would
    /// behave incorrectly. `overflow` ranks highest because it's a signal
    /// that the watcher lost track of state entirely and a full rescan is
    /// needed.
    var priority: Int {
        switch self {
        case .overflow: 5
        case .removed: 4
        case .renamed: 3
        case .created: 2
        case .modified: 1
        case .unknown: 0
        }
    }
}
