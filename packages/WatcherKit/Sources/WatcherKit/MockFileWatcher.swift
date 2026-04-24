import Foundation
import PlatformKit

/// In-memory ``FileWatcher`` for tests and previews.
///
/// Exposes `emit(_:)` / `emit(many:)` so tests can inject events deterministically
/// and assert on what consumers see. The backing storage is an `AsyncStream`
/// continuation held behind an actor so calls are safe from any thread.
///
/// Usage:
/// ```swift
/// let mock = MockFileWatcher()
/// let stream = mock.start(paths: [URL(fileURLWithPath: "/tmp/repo")])
/// Task {
///     for await event in stream { print(event) }
/// }
/// await mock.emit(WatchEvent(path: url, kind: .modified))
/// await mock.stop()
/// ```
public final class MockFileWatcher: FileWatcher, @unchecked Sendable {
    private let state = State()

    public init() {}

    public func start(paths _: [URL]) -> AsyncStream<WatchEvent> {
        AsyncStream<WatchEvent> { continuation in
            Task { await state.attach(continuation) }
        }
    }

    public func stop() async {
        await state.finish()
    }

    /// Emit a single event to subscribers.
    public func emit(_ event: WatchEvent) async {
        await state.yield(event)
    }

    /// Emit a batch of events in order.
    public func emit(many events: [WatchEvent]) async {
        await state.yield(many: events)
    }

    // MARK: - internal state

    private actor State {
        private var continuation: AsyncStream<WatchEvent>.Continuation?
        private var pending: [WatchEvent] = []

        func attach(_ cont: AsyncStream<WatchEvent>.Continuation) {
            if continuation != nil {
                preconditionFailure("MockFileWatcher.start called twice")
            }
            continuation = cont
            for event in pending {
                cont.yield(event)
            }
            pending.removeAll()
        }

        func yield(_ event: WatchEvent) {
            if let continuation {
                continuation.yield(event)
            } else {
                pending.append(event)
            }
        }

        func yield(many events: [WatchEvent]) {
            for event in events {
                yield(event)
            }
        }

        func finish() {
            continuation?.finish()
            continuation = nil
            pending.removeAll()
        }
    }
}
