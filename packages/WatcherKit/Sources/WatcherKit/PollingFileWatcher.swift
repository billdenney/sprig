import Foundation
import PlatformKit

/// Portable ``FileWatcher`` that periodically rescans a set of roots and
/// emits events for any deltas it detects.
///
/// **Use it when:** running on Linux/Windows (no FSEvents), or on a
/// network/iCloud volume where FSEvents is unreliable (per ADR 0022 —
/// "best-effort with auto-fallback to polling on non-local volumes"), or
/// in tests where deterministic behavior matters more than wall-clock
/// efficiency.
///
/// **Don't use it when:** local-disk macOS scale matters — FSEvents is
/// orders of magnitude cheaper. ``FSEventsWatcher`` is the right choice
/// there.
///
/// The polling task captures an initial snapshot, sleeps ``pollInterval``,
/// snapshots again, diffs, and yields events. The diff is metadata-only
/// (size + mtime) — no content hashing — so the per-tick cost is one
/// `stat` per file.
///
/// Lifecycle is wired so:
/// - The polling task is spawned the moment a consumer subscribes to the
///   ``AsyncStream``.
/// - It runs until either (a) ``stop()`` is called, or (b) the consumer
///   cancels its iterating task (which fires `onTermination` and
///   cancels the polling task).
public final class PollingFileWatcher: FileWatcher, @unchecked Sendable {
    /// Wall-clock time between rescans.
    public let pollInterval: TimeInterval

    private let state = LifecycleState()

    public init(pollInterval: TimeInterval = 1.0) {
        precondition(pollInterval > 0, "pollInterval must be positive")
        self.pollInterval = pollInterval
    }

    public func start(paths: [URL]) -> AsyncStream<WatchEvent> {
        let interval = pollInterval
        let state = state
        return AsyncStream<WatchEvent> { continuation in
            let task = Task<Void, Never> {
                var snapshot = Self.takeSnapshot(of: paths)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        break
                    }
                    if Task.isCancelled { break }
                    let updated = Self.takeSnapshot(of: paths)
                    for event in Self.diff(old: snapshot, new: updated) {
                        continuation.yield(event)
                    }
                    snapshot = updated
                }
                continuation.finish()
            }
            Task { await state.attach(task: task) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await state.detach() }
            }
        }
    }

    public func stop() async {
        await state.cancelAndWait()
    }

    // MARK: - Snapshot + diff (pure)

    /// Recursive directory walk producing per-path metadata. Static so the
    /// polling Task closure doesn't capture `self`.
    static func takeSnapshot(of roots: [URL]) -> [URL: FileMetadata] {
        var out: [URL: FileMetadata] = [:]
        for root in roots {
            walk(root, into: &out)
        }
        return out
    }

    private static func walk(_ url: URL, into out: inout [URL: FileMetadata]) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        let isDir = values.isDirectory ?? false
        let size = UInt64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate ?? .distantPast
        out[url.standardized] = FileMetadata(size: size, mtime: mtime, isDir: isDir)

        guard isDir else { return }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            walk(child, into: &out)
        }
    }

    /// Pure diff — exposed `internal` for tests.
    static func diff(
        old: [URL: FileMetadata],
        new: [URL: FileMetadata],
        timestamp: Date = Date()
    ) -> [WatchEvent] {
        var events: [WatchEvent] = []
        for (url, meta) in new {
            if let prior = old[url] {
                if prior.size != meta.size || prior.mtime != meta.mtime {
                    events.append(WatchEvent(path: url, kind: .modified, timestamp: timestamp))
                }
            } else {
                events.append(WatchEvent(path: url, kind: .created, timestamp: timestamp))
            }
        }
        for url in old.keys where new[url] == nil {
            events.append(WatchEvent(path: url, kind: .removed, timestamp: timestamp))
        }
        return events
    }
}

// MARK: - Internal types

/// File metadata fingerprint — what we compare across snapshots.
struct FileMetadata: Equatable {
    let size: UInt64
    let mtime: Date
    let isDir: Bool
}

/// Tracks the polling task so `stop()` can cancel it deterministically.
/// Actor-isolated so it's portable across macOS, Linux, and Windows
/// (`OSAllocatedUnfairLock` is macOS-13+ only and would lose us Linux).
private actor LifecycleState {
    private var task: Task<Void, Never>?

    func attach(task: Task<Void, Never>) {
        self.task = task
    }

    func detach() {
        task = nil
    }

    func cancelAndWait() async {
        let pending = task
        task = nil
        pending?.cancel()
        // Wait for the polling Task's `continuation.finish()` so callers
        // can rely on stop() meaning "stream is done."
        _ = await pending?.value
    }
}
