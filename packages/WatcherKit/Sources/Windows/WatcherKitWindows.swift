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
        /// One watched directory's open HANDLE plus the URL it was
        /// opened from. The HANDLE is closed in ``stop()``.
        private struct WatchedRoot: @unchecked Sendable {
            let handle: HANDLE
            let url: URL
        }

        private struct State: @unchecked Sendable {
            var roots: [WatchedRoot] = []
            var tasks: [Task<Void, Never>] = []
            var continuation: AsyncStream<WatchEvent>.Continuation?
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
            // is a no-op.
            lock.lock()
            let rootsToClose = state.roots
            let tasksToWait = state.tasks
            let cont = state.continuation
            state.roots = []
            state.tasks = []
            state.continuation = nil
            lock.unlock()

            // (1) Mark each Task cancelled so its loop sees
            //     `Task.isCancelled` after the blocking I/O wakes.
            for task in tasksToWait {
                task.cancel()
            }

            // (2) Wake any in-flight `ReadDirectoryChangesW` so the
            //     loops actually return and observe cancellation.
            //     `CancelIoEx(handle, nil)` cancels every pending I/O
            //     on the handle issued by the calling process.
            for root in rootsToClose {
                _ = CancelIoEx(root.handle, nil)
            }

            // (3) Wait for each Task to finish unwinding before we
            //     close the handle out from under it (closing while
            //     `ReadDirectoryChangesW` is still pending is
            //     undefined per `winbase.h`).
            for task in tasksToWait {
                _ = await task.value
            }

            // (4) Now safe to close handles.
            for root in rootsToClose {
                _ = CloseHandle(root.handle)
            }

            cont?.finish()
        }

        // MARK: - Setup

        private func attach(
            continuation: AsyncStream<WatchEvent>.Continuation,
            paths: [URL]
        ) {
            var openedRoots: [WatchedRoot] = []
            var spawnedTasks: [Task<Void, Never>] = []

            for path in paths {
                guard let handle = Self.openDirectoryHandle(at: path) else {
                    continue
                }
                let root = WatchedRoot(handle: handle, url: path)
                let task = Task<Void, Never>.detached(priority: .utility) {
                    Self.runWatchLoop(for: root, continuation: continuation)
                }
                openedRoots.append(root)
                spawnedTasks.append(task)
            }

            if openedRoots.isEmpty {
                continuation.finish()
                return
            }

            lock.lock()
            if state.continuation != nil {
                lock.unlock()
                preconditionFailure("ReadDirectoryChangesWatcher.start called twice")
            }
            state.roots = openedRoots
            state.tasks = spawnedTasks
            state.continuation = continuation
            lock.unlock()
        }

        /// Open a directory HANDLE suitable for `ReadDirectoryChangesW`.
        /// Returns nil on failure (path doesn't exist, permission
        /// denied, etc.); caller skips that path.
        private static func openDirectoryHandle(at url: URL) -> HANDLE? {
            // `CreateFileW` takes UTF-16; build a null-terminated
            // wide-char array from the URL's path.
            let pathString = url.path
            var wide = Array(pathString.utf16)
            wide.append(0) // null terminator

            let handle = wide.withUnsafeBufferPointer { buf -> HANDLE? in
                let h = CreateFileW(
                    buf.baseAddress,
                    DWORD(FILE_LIST_DIRECTORY),
                    DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                    nil,
                    DWORD(OPEN_EXISTING),
                    // BACKUP_SEMANTICS is required to open a
                    // directory; it permits opening anything the
                    // caller has SE_BACKUP_NAME for, which on a
                    // user-owned directory is just the directory
                    // itself. No security implications for our use.
                    DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                    nil
                )
                return h == INVALID_HANDLE_VALUE ? nil : h
            }
            return handle
        }

        // MARK: - Watch loop

        /// Filter mask covering the same event categories
        /// `PollingFileWatcher` surfaces. Adjust if the
        /// ``FileWatcher`` protocol grows finer-grained kinds.
        private static let notifyFilter: DWORD = DWORD(
            FILE_NOTIFY_CHANGE_FILE_NAME
                | FILE_NOTIFY_CHANGE_DIR_NAME
                | FILE_NOTIFY_CHANGE_LAST_WRITE
                | FILE_NOTIFY_CHANGE_SIZE
                | FILE_NOTIFY_CHANGE_CREATION
                | FILE_NOTIFY_CHANGE_ATTRIBUTES
        )

        /// 64 KiB buffer for one `ReadDirectoryChangesW` cycle.
        /// Microsoft docs say larger buffers are clamped at 64 KiB on
        /// some FS drivers anyway; smaller buffers risk
        /// `bytesReturned == 0` (overflow signal) on busy roots.
        private static let bufferByteCount: Int = 64 * 1024

        /// Per-root watch loop. Synchronous (blocks in
        /// `ReadDirectoryChangesW`); cancelled by `CancelIoEx` from
        /// ``stop()``.
        private static func runWatchLoop(
            for root: WatchedRoot,
            continuation: AsyncStream<WatchEvent>.Continuation
        ) {
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: bufferByteCount,
                alignment: MemoryLayout<DWORD>.alignment
            )
            defer { buffer.deallocate() }

            while !Task.isCancelled {
                var bytesReturned: DWORD = 0
                let success = ReadDirectoryChangesW(
                    root.handle,
                    buffer,
                    DWORD(bufferByteCount),
                    true, // bWatchSubtree — recurse into subdirectories
                    notifyFilter,
                    &bytesReturned,
                    nil, // lpOverlapped (synchronous)
                    nil // lpCompletionRoutine
                )

                if success == 0 {
                    // CancelIoEx during stop() lands here with
                    // ERROR_OPERATION_ABORTED. Other errors are
                    // unrecoverable (handle invalid, FS unmounted,
                    // etc.).
                    let err = GetLastError()
                    if err != DWORD(ERROR_OPERATION_ABORTED) {
                        continuation.yield(WatchEvent(
                            path: root.url,
                            kind: .overflow,
                            timestamp: Date()
                        ))
                    }
                    return
                }

                if bytesReturned == 0 {
                    // Kernel ran out of buffer space and dropped
                    // events. ``WatchEventKind/overflow`` tells
                    // callers to rescan from scratch.
                    continuation.yield(WatchEvent(
                        path: root.url,
                        kind: .overflow,
                        timestamp: Date()
                    ))
                    continue
                }

                parseAndEmit(
                    buffer: buffer,
                    byteCount: Int(bytesReturned),
                    under: root,
                    continuation: continuation
                )
            }
        }

        /// Parse a buffer of `FILE_NOTIFY_INFORMATION` records and
        /// emit one `WatchEvent` per record.
        ///
        /// Record layout (per `winnt.h`):
        ///
        /// ```
        /// DWORD NextEntryOffset;  // bytes from start of this record to next; 0 = last
        /// DWORD Action;           // FILE_ACTION_*
        /// DWORD FileNameLength;   // FileName size in bytes (not chars)
        /// WCHAR FileName[1];      // variable-length UTF-16, NOT null-terminated
        /// ```
        ///
        /// `FileName` is path-relative-to-root with backslash
        /// separators; we convert to forward slashes when composing
        /// the URL so downstream consumers see the same shape as
        /// macOS / Linux.
        private static func parseAndEmit(
            buffer: UnsafeMutableRawPointer,
            byteCount: Int,
            under root: WatchedRoot,
            continuation: AsyncStream<WatchEvent>.Continuation
        ) {
            let now = Date()
            var offset = 0
            // Each record's header is 12 bytes (3 DWORDs); guard
            // against truncation.
            while offset + 12 <= byteCount {
                let recordPtr = buffer.advanced(by: offset)
                let nextEntryOffset = recordPtr.load(as: DWORD.self, fromByteOffset: 0)
                let action = recordPtr.load(as: DWORD.self, fromByteOffset: 4)
                let nameLengthBytes = Int(recordPtr.load(as: DWORD.self, fromByteOffset: 8))
                let nameWordCount = nameLengthBytes / 2 // bytes -> UInt16 (WCHAR)

                if nameWordCount > 0,
                   offset + 12 + nameLengthBytes <= byteCount {
                    let nameStart = recordPtr.advanced(by: 12)
                    var chars = [UInt16](repeating: 0, count: nameWordCount + 1)
                    chars.withUnsafeMutableBufferPointer { dst in
                        if let base = dst.baseAddress {
                            base.update(
                                from: nameStart.assumingMemoryBound(to: UInt16.self),
                                count: nameWordCount
                            )
                        }
                    }
                    // chars[nameWordCount] stays 0 — null terminator
                    // for `String(decodingCString:)`.
                    let relativeBackslashed = String(decodingCString: chars, as: UTF16.self)
                    let relativeForward = relativeBackslashed.replacingOccurrences(
                        of: "\\",
                        with: "/"
                    )
                    let url = root.url.appendingPathComponent(relativeForward)
                    continuation.yield(WatchEvent(
                        path: url,
                        kind: mapAction(action),
                        timestamp: now
                    ))
                }

                if nextEntryOffset == 0 { break }
                offset += Int(nextEntryOffset)
            }
        }

        private static func mapAction(_ action: DWORD) -> WatchEventKind {
            switch action {
            case DWORD(FILE_ACTION_ADDED):
                .created
            case DWORD(FILE_ACTION_REMOVED):
                .removed
            case DWORD(FILE_ACTION_MODIFIED):
                .modified
            case DWORD(FILE_ACTION_RENAMED_OLD_NAME),
                 DWORD(FILE_ACTION_RENAMED_NEW_NAME):
                .renamed
            default:
                .unknown
            }
        }
    }
#endif
