#if os(Windows)
    import Foundation
    import PlatformKit
    import WinSDK

    // Static, stateless machinery for one `ReadDirectoryChangesW`
    // watch loop. Split out to keep `WatcherKitWindows.swift` under
    // SwiftLint's `file_length` / `type_body_length` caps; the
    // functions here don't reference instance state so the
    // namespace-only enum is the right home for them.

    /// One watched directory's open HANDLE plus the URL it was
    /// opened from. Closed in `ReadDirectoryChangesWatcher.stop()`.
    /// Module-internal so the class + the helpers below can share it.
    struct WatchedRoot: @unchecked Sendable {
        let handle: HANDLE
        let url: URL
    }

    /// Namespace for the synchronous machinery a per-root Task runs.
    /// The `onReady` callback fires exactly once, before the first
    /// `ReadDirectoryChangesW` invocation, so test fixtures can
    /// `await watcher.awaitReady()` rather than guess a sleep
    /// duration.
    enum WindowsWatchLoop {
        /// Filter mask covering the same event categories
        /// `PollingFileWatcher` surfaces. Adjust if the
        /// ``FileWatcher`` protocol grows finer-grained kinds.
        static let notifyFilter: DWORD = .init(
            FILE_NOTIFY_CHANGE_FILE_NAME
                | FILE_NOTIFY_CHANGE_DIR_NAME
                | FILE_NOTIFY_CHANGE_LAST_WRITE
                | FILE_NOTIFY_CHANGE_SIZE
                | FILE_NOTIFY_CHANGE_CREATION
                | FILE_NOTIFY_CHANGE_ATTRIBUTES
        )

        /// 64 KiB buffer for one `ReadDirectoryChangesW` cycle.
        /// Microsoft docs say larger buffers are clamped at 64 KiB
        /// on some FS drivers anyway; smaller buffers risk
        /// `bytesReturned == 0` (overflow signal) on busy roots.
        static let bufferByteCount: Int = 64 * 1024

        /// Open a directory HANDLE suitable for
        /// `ReadDirectoryChangesW`. Returns nil on failure (path
        /// doesn't exist, permission denied, etc.); caller skips
        /// that path.
        static func openDirectoryHandle(at url: URL) -> HANDLE? {
            // `CreateFileW` takes UTF-16; build a null-terminated
            // wide-char array from the URL's path.
            let pathString = url.path
            var wide = Array(pathString.utf16)
            wide.append(0) // null terminator

            return wide.withUnsafeBufferPointer { buf -> HANDLE? in
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
        }

        /// Per-root watch loop. Synchronous (blocks in
        /// `ReadDirectoryChangesW`); cancelled by `CancelIoEx` from
        /// `ReadDirectoryChangesWatcher.stop()`.
        ///
        /// `onReady` fires once, immediately before the first
        /// `ReadDirectoryChangesW` invocation. There's a
        /// microsecond-scale userspace gap between the callback and
        /// the syscall, but `awaitReady`'s contract is "any
        /// filesystem mutation from now on will be observed" and the
        /// gap is dwarfed by the latency of any test client firing a
        /// mutation (Swift runtime + Foundation overhead ≫ µs).
        static func run(
            for root: WatchedRoot,
            continuation: AsyncStream<WatchEvent>.Continuation,
            onReady: @escaping @Sendable () -> Void
        ) {
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: bufferByteCount,
                alignment: MemoryLayout<DWORD>.alignment
            )
            defer { buffer.deallocate() }

            var hasSignaledReady = false
            while !Task.isCancelled {
                if !hasSignaledReady {
                    onReady()
                    hasSignaledReady = true
                }
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

                if !success {
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
        static func parseAndEmit(
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
                let nextEntryOffset = recordPtr.load(fromByteOffset: 0, as: DWORD.self)
                let action = recordPtr.load(fromByteOffset: 4, as: DWORD.self)
                let nameLengthBytes = Int(recordPtr.load(fromByteOffset: 8, as: DWORD.self))
                let nameWordCount = nameLengthBytes / 2 // bytes -> UInt16 (WCHAR)

                let hasParseableName = nameWordCount > 0
                    && offset + 12 + nameLengthBytes <= byteCount
                if hasParseableName {
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

        static func mapAction(_ action: DWORD) -> WatchEventKind {
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
