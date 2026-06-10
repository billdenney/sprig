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
        /// Latched by ``finish()``. Load-bearing for the
        /// stop-before-attach race: `start(paths:)` attaches the
        /// continuation via an unstructured Task (an async actor
        /// hop), so a fast `stop()` can reach this actor FIRST. A
        /// nil-continuation finish must not be lost — without the
        /// latch, the late attach installs a continuation nobody
        /// will ever finish and the consumer's `for await` hangs
        /// forever (bit WatcherKitTests intermittently ~1-in-5 full
        /// runs; the main-snapshot toolchain's scheduling widened
        /// the window).
        private var finished = false

        func attach(_ cont: AsyncStream<WatchEvent>.Continuation) {
            if continuation != nil {
                preconditionFailure("MockFileWatcher.start called twice")
            }
            // Deliver everything emitted before the attach hop won
            // the actor, THEN honor a finish that raced in ahead.
            for event in pending {
                cont.yield(event)
            }
            pending.removeAll()
            if finished {
                cont.finish()
                return
            }
            continuation = cont
        }

        func yield(_ event: WatchEvent) {
            guard !finished else { return }
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
            finished = true
            continuation?.finish()
            continuation = nil
        }
    }
}
