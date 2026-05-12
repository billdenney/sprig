#if os(Windows)
    import Foundation
    import PlatformKit
    import WinSDK

    /// Windows ``FileWatcher`` backed by `ReadDirectoryChangesW`.
    ///
    /// One open directory ``HANDLE`` per watched root, plus a detached
    /// `Task` per root that blocks in `ReadDirectoryChangesW` and
    /// emits ``WatchEvent`` values as the kernel surfaces filesystem
    /// changes. This is the reactive counterpart to the polling
    /// fallback (``PollingFileWatcher``); on local NTFS volumes the
    /// kernel notifies in milliseconds and there's no `readdir`
    /// scan-delay to wait out.
    ///
    /// Verification: this file is structured for correctness but only
    /// exercised on Windows (CI-Windows unit tests + manual
    /// validation). The polling watcher remains available as a
    /// fallback on volumes where ReadDirectoryChangesW is unsupported
    /// (some network shares, some virtualized filesystems).
    ///
    /// See `docs/architecture/fs-watching.md` for the full strategy.
    public final class ReadDirectoryChangesWatcher: FileWatcher, @unchecked Sendable {
        // `WatchedRoot` and the static `WindowsWatchLoop` namespace
        // live in `WindowsWatchLoop.swift` — same module, internal
        // visibility — to keep this file under SwiftLint's
        // `file_length` cap.

        private struct State: @unchecked Sendable {
            var roots: [WatchedRoot] = []
            var tasks: [Task<Void, Never>] = []
            var continuation: AsyncStream<WatchEvent>.Continuation?

            /// True once ``start(paths:)`` has been called at least
            /// once. Distinguishes "never started, awaitReady must
            /// queue" from "all per-root Tasks have signaled ready,
            /// awaitReady resumes immediately."
            var startedAtLeastOnce = false

            /// Per-root Tasks that haven't yet signaled "I've
            /// registered the kernel notification." Decremented by
            /// ``markRootReady()`` from each Task's preamble; when
            /// it reaches 0 we resume every queued awaitReady caller.
            var pendingReadyCount = 0

            /// `awaitReady` callers parked here while
            /// `pendingReadyCount > 0`. Resumed by
            /// ``markRootReady()`` when the counter hits 0, or by
            /// ``stop()`` so they don't hang on a torn-down watcher.
            var readyContinuations: [CheckedContinuation<Void, Never>] = []
        }

        private let lock = NSLock()
        private nonisolated(unsafe) var state = State()

        public init() {}

        public func start(paths: [URL]) -> AsyncStream<WatchEvent> {
            AsyncStream<WatchEvent> { [weak self] continuation in
                guard let self else {
                    continuation.finish()
                    return
                }
                self.attach(continuation: continuation, paths: paths)
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.stop() }
                }
            }
        }

        public func stop() async {
            // Atomically grab and clear state so a concurrent stop()
            // is a no-op. `NSLock.withLock` is the async-safe shape:
            // bare `lock()` / `unlock()` are `@unavailable` from
            // async contexts in Swift 6 on Windows.
            //
            // We return the whole `State` snapshot (a value type) so
            // the call doesn't trip SwiftLint's `large_tuple` rule.
            // `startedAtLeastOnce` stays `true` post-stop so a
            // post-stop awaitReady() resumes immediately rather than
            // hanging.
            let snapshot: State = lock.withLock {
                let snap = state
                state.roots = []
                state.tasks = []
                state.continuation = nil
                state.pendingReadyCount = 0
                state.readyContinuations = []
                return snap
            }

            // (1) Mark each Task cancelled so its loop sees
            //     `Task.isCancelled` after the blocking I/O wakes.
            for task in snapshot.tasks {
                task.cancel()
            }

            // (2) Wake any in-flight `ReadDirectoryChangesW` so the
            //     loops actually return and observe cancellation.
            //     `CancelIoEx(handle, nil)` cancels every pending I/O
            //     on the handle issued by the calling process.
            for root in snapshot.roots {
                _ = CancelIoEx(root.handle, nil)
            }

            // (3) Wait for each Task to finish unwinding before we
            //     close the handle out from under it (closing while
            //     `ReadDirectoryChangesW` is still pending is
            //     undefined per `winbase.h`).
            for task in snapshot.tasks {
                _ = await task.value
            }

            // (4) Now safe to close handles.
            for root in snapshot.roots {
                _ = CloseHandle(root.handle)
            }

            snapshot.continuation?.finish()

            // (5) Resume any awaitReady() callers that were parked
            //     before any Task got a chance to signal ready.
            //     Without this they'd hang forever waiting for a
            //     watcher that's already gone.
            for continuation in snapshot.readyContinuations {
                continuation.resume()
            }
        }

        // MARK: - awaitReady

        /// Wait until every per-root `ReadDirectoryChangesW`
        /// notification request has been registered with the kernel.
        ///
        /// Each per-root Task signals "ready" inside its preamble,
        /// immediately before its first synchronous
        /// `ReadDirectoryChangesW` call. There's a microsecond-scale
        /// userspace gap between the signal and the syscall, but no
        /// observable test client can fire a filesystem mutation
        /// faster than that gap (the mutation itself goes through
        /// `Data.write(to:)` + `WriteFile` + close, hundreds of µs
        /// minimum). In practice this gives deterministic
        /// "watcher-is-live" semantics for tests.
        ///
        /// Must be called after ``start(paths:)``. Calling it
        /// without an intervening `start` will block forever (a
        /// deliberate misuse trap rather than a silent no-op).
        public func awaitReady() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard state.startedAtLeastOnce else {
                        // start() hasn't run yet — queue and wait.
                        state.readyContinuations.append(continuation)
                        return false
                    }
                    guard state.pendingReadyCount > 0 else {
                        // All roots have already signaled ready,
                        // OR no roots were spawned (e.g.
                        // start(paths: []) or all paths invalid).
                        return true
                    }
                    state.readyContinuations.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        /// Per-root Task callback: "I've registered with the kernel."
        /// Decrements ``State/pendingReadyCount`` and, if it hits
        /// zero, drains and resumes every parked ``awaitReady`` caller.
        ///
        /// Called from the synchronous body of the detached Task
        /// (not from an async context); the lock is taken
        /// synchronously and continuations are resumed AFTER the
        /// lock is released to avoid any chance of re-entry.
        private func markRootReady() {
            let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                if state.pendingReadyCount > 0 {
                    state.pendingReadyCount -= 1
                }
                guard state.pendingReadyCount == 0 else { return [] }
                let pending = state.readyContinuations
                state.readyContinuations = []
                return pending
            }
            for continuation in toResume {
                continuation.resume()
            }
        }

        // MARK: - Setup

        private func attach(
            continuation: AsyncStream<WatchEvent>.Continuation,
            paths: [URL]
        ) {
            var openedRoots: [WatchedRoot] = []
            var spawnedTasks: [Task<Void, Never>] = []

            for path in paths {
                guard let handle = WindowsWatchLoop.openDirectoryHandle(at: path) else {
                    continue
                }
                let root = WatchedRoot(handle: handle, url: path)
                let task = Task<Void, Never>.detached(priority: .utility) { [weak self] in
                    WindowsWatchLoop.run(
                        for: root,
                        continuation: continuation,
                        onReady: { [weak self] in self?.markRootReady() }
                    )
                }
                openedRoots.append(root)
                spawnedTasks.append(task)
            }

            // Wire up the state + readyness counter atomically.
            // `startedAtLeastOnce = true` always; `pendingReadyCount`
            // tracks tasks that haven't entered their first
            // `ReadDirectoryChangesW` yet. For the empty-roots edge
            // case (no paths opened) this stays 0 and any awaitReady
            // call resumes immediately.
            let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                if state.continuation != nil {
                    preconditionFailure("ReadDirectoryChangesWatcher.start called twice")
                }
                state.roots = openedRoots
                state.tasks = spawnedTasks
                state.continuation = openedRoots.isEmpty ? nil : continuation
                state.startedAtLeastOnce = true
                state.pendingReadyCount = openedRoots.count
                // If we won't be spawning any per-root Tasks,
                // there's no one to call `markRootReady`. Drain
                // queued waiters right now so they're not stuck.
                guard openedRoots.isEmpty else { return [] }
                let pending = state.readyContinuations
                state.readyContinuations = []
                return pending
            }

            if openedRoots.isEmpty {
                continuation.finish()
            }
            for continuation in toResume {
                continuation.resume()
            }
        }
    }
#endif
