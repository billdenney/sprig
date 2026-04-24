#if os(macOS)
    import CoreServices
    import Foundation
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

        private let lock = NSLock()
        private var stream: FSEventStreamRef?
        private var continuation: AsyncStream<WatchEvent>.Continuation?

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
            lock.lock()
            let s = stream
            stream = nil
            continuation?.finish()
            continuation = nil
            lock.unlock()
            if let s {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
        }

        private func attach(
            continuation: AsyncStream<WatchEvent>.Continuation,
            paths: [URL]
        ) {
            lock.lock()
            if self.continuation != nil {
                lock.unlock()
                preconditionFailure("FSEventsWatcher.start called twice")
            }
            self.continuation = continuation
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

            guard let s = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                coalesceInterval,
                flags
            ) else {
                lock.unlock()
                continuation.finish()
                return
            }

            stream = s
            lock.unlock()

            FSEventStreamSetDispatchQueue(
                s,
                DispatchQueue.global(qos: .utility)
            )
            FSEventStreamStart(s)
        }

        fileprivate func dispatch(
            paths: UnsafePointer<UnsafePointer<CChar>?>,
            flags: UnsafePointer<FSEventStreamEventFlags>,
            count: Int
        ) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            lock.unlock()

            let now = Date()
            for i in 0 ..< count {
                guard let cstr = paths[i] else { continue }
                let path = String(cString: cstr)
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
        private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            let paths = unsafeBitCast(
                eventPaths,
                to: UnsafePointer<UnsafePointer<CChar>?>.self
            )
            watcher.dispatch(paths: paths, flags: eventFlags, count: numEvents)
        }
    }
#endif
