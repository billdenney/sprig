import Foundation

/// Watches a set of filesystem paths and streams back change events.
///
/// Implementations live in `WatcherKit`: `FSEventsWatcher` on macOS,
/// `INotifyWatcher` on Linux, `ReadDirectoryChangesWatcher` on Windows.
/// A `MockFileWatcher` exists in `WatcherKit` for use in tests elsewhere
/// in the repo.
///
/// Design notes
/// ------------
/// - The protocol is `Sendable` so it can freely cross actor boundaries and
///   be stored in `RepoState` actors.
/// - Events arrive via `AsyncStream` rather than a callback — callers can
///   use structured concurrency (`for await` inside a `Task`) and cancel
///   cleanly by cancelling the task.
/// - No guarantees about event granularity. FSEvents/inotify/ReadDirChangesW
///   each coalesce in their own ways; consumers must tolerate duplicates
///   and must not assume ordering beyond "events for a given path arrive
///   monotonically in time." Use ``EventCoalescer`` if you need stable
///   de-duplication windows.
public protocol FileWatcher: Sendable {
    /// Begin watching `paths`. Returns an `AsyncStream` that yields
    /// ``WatchEvent`` values until either ``stop()`` is called or the
    /// consuming task is cancelled.
    ///
    /// Calling `start` twice is a programmer error and traps in debug.
    func start(paths: [URL]) -> AsyncStream<WatchEvent>

    /// Stop the watcher. Idempotent. After this returns, the stream
    /// previously vended by ``start(paths:)`` will finish.
    func stop() async
}

/// A single filesystem change observation.
///
/// The exact semantics of the `kind` depends on the underlying platform
/// API; see ``WatchEventKind``.
public struct WatchEvent: Sendable, Hashable {
    /// Absolute path the event is about.
    public let path: URL

    /// What happened at that path.
    public let kind: WatchEventKind

    /// When the event was observed. Used by ``EventCoalescer`` to window
    /// duplicates.
    public let timestamp: Date

    public init(path: URL, kind: WatchEventKind, timestamp: Date = Date()) {
        self.path = path
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// The classification of a filesystem event.
///
/// These map to the common subset of what FSEvents, inotify, and
/// ReadDirectoryChangesW all report. Platforms may combine or collapse
/// kinds — ``unknown`` is the safe fallback.
public enum WatchEventKind: Sendable, Hashable, CaseIterable {
    /// A new item appeared at the path (created, moved-in, renamed-into).
    case created
    /// Existing item's contents or metadata changed.
    case modified
    /// Item disappeared (deleted, moved-out, renamed-out).
    case removed
    /// Item renamed — both the source and destination observations use this.
    case renamed
    /// The watcher hit a buffer overflow or similar; the consumer should
    /// treat the watched roots as dirty and rescan from scratch.
    case overflow
    /// The platform reported an event we don't know how to classify.
    case unknown
}
