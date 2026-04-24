#if os(macOS)
    import CoreServices
    import Foundation
    import os
    import PlatformKit

    /// macOS ``FileWatcher`` backed by FSEvents.
    ///
    /// Creates an `FSEventStream` on the union of the requested paths, with
    /// ``coalesceInterval`` as the FSEvents latency (the kernel's own
    /// coalescing window). Additional path-level dedupe should be layered
    /// on top via ``PlatformKit/EventCoalescer`` — FSEvents still emits
    /// duplicates for rapid editor-save sequences.
    ///
    /// Verification: this file is structured for correctness but only
    /// exercised on a Mac (CI-macOS unit tests + local developer sanity).
    /// See `docs/architecture/fs-watching.md` for the full strategy.
    public final class FSEventsWatcher: FileWatcher, @unchecked Sendable {
        /// FSEvents latency in seconds. Apple recommends 0.1–1.0. 0.25 gives
        /// us a balance between responsiveness and kernel-side coalescing.
        public var coalesceInterval: CFTimeInterval = 0.25

        private struct State {
            var stream: FSEventStreamRef?
            var continuation: AsyncStream<WatchEvent>.Continuation?
        }

        /// `OSAllocatedUnfairLock` is Apple's async-safe replacement for
        /// `NSLock` (macOS 13+; Sprig requires macOS 14+). `withLock` is
        /// explicitly callable from async contexts — `NSLock.lock()` is
        /// `@unavailable` from async contexts in Swift 6.
        private let state = OSAllocatedUnfairLock(initialState: State())

        public init() {}

        public func start(paths: [URL]) -> AsyncStream<WatchEvent> {
            AsyncStream<WatchEvent> { [weak self] continuation in
                guard let self else {
                    continuation.finish()
                    return
                }
                attach(continuation: continuation, paths: paths)
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.stop() }
                }
            }
        }

        public func stop() async {
            let (stream, cont) = state.withLock { state -> (FSEventStreamRef?, AsyncStream<WatchEvent>.Continuation?) in
                let s = state.stream
                let c = state.continuation
                state.stream = nil
                state.continuation = nil
                return (s, c)
            }
            cont?.finish()
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }

        private func attach(
            continuation: AsyncStream<WatchEvent>.Continuation,
            paths: [URL]
        ) {
            let pathsToWatch = paths.map(\.path) as CFArray

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let flags: FSEventStreamCreateFlags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagIgnoreSelf
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                coalesceInterval,
                flags
            ) else {
                continuation.finish()
                return
            }

            state.withLock { state in
                if state.continuation != nil {
                    preconditionFailure("FSEventsWatcher.start called twice")
                }
                state.stream = stream
                state.continuation = continuation
            }

            FSEventStreamSetDispatchQueue(
                stream,
                DispatchQueue.global(qos: .utility)
            )
            FSEventStreamStart(stream)
        }

        fileprivate func dispatch(
            paths: UnsafePointer<UnsafePointer<CChar>>,
            flags: UnsafePointer<FSEventStreamEventFlags>,
            count: Int
        ) {
            let continuation = state.withLock { $0.continuation }
            guard let continuation else { return }

            let now = Date()
            for i in 0 ..< count {
                let path = String(cString: paths[i])
                let kind = classify(flags: flags[i])
                continuation.yield(WatchEvent(
                    path: URL(fileURLWithPath: path),
                    kind: kind,
                    timestamp: now
                ))
            }
        }

        private func classify(flags: FSEventStreamEventFlags) -> WatchEventKind {
            let f = Int(flags)
            if f & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                return .overflow
            }
            if f & kFSEventStreamEventFlagItemRemoved != 0 {
                return .removed
            }
            if f & kFSEventStreamEventFlagItemRenamed != 0 {
                return .renamed
            }
            if f & kFSEventStreamEventFlagItemCreated != 0 {
                return .created
            }
            if f & (
                kFSEventStreamEventFlagItemModified
                    | kFSEventStreamEventFlagItemInodeMetaMod
                    | kFSEventStreamEventFlagItemChangeOwner
                    | kFSEventStreamEventFlagItemXattrMod
            ) != 0 {
                return .modified
            }
            return .unknown
        }

        /// FSEvents requires a C function pointer. We bounce into the Swift
        /// instance via the stashed `info` pointer on the context.
        ///
        /// `eventPaths` is a `const char *const *` (array of C strings) because
        /// we don't set `kFSEventStreamCreateFlagUseCFTypes`. `assumingMemoryBound`
        /// gives us a safely-typed view without the `unsafeBitCast`
        /// undefined-behavior warning.
        private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            watcher.dispatch(paths: paths, flags: eventFlags, count: numEvents)
        }
    }
#endif
