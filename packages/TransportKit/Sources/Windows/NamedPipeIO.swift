// NamedPipeIO.swift
//
// Internal helpers + value types for `NamedPipeTransport`. Split out
// of the main file to stay under SwiftLint's file_length / type_body
// caps as the OVERLAPPED-I/O surface grew (see ADR 0067).
//
// What's here:
// - `SendableHandle`: an `@unchecked Sendable` wrapper for Win32
//   `HANDLE` so we can carry pipe + event handles into GCD closures
//   under Swift 6 strict-concurrency. MSDN documents these handles as
//   safe to share across threads; the wrapper makes that auditable.
// - `NamedPipeIO.readExactlyOverlapped(...)`: the OVERLAPPED-mode
//   blocking read with cancel-event support, used by the read loop.
// - `NamedPipeIO.acceptClient(...)`: the OVERLAPPED-mode
//   `ConnectNamedPipe` wait with cancel-event support, used by
//   `NamedPipeServer`'s multi-client accept loop.
// - `NamedPipeIO.canonicalPipePath(...)`: pipe-name canonicalization
//   (prepends `\\.\pipe\` if not already present).
// - `NamedPipeIO.bufferSize`: kernel buffer constant for
//   `CreateNamedPipeW`.

#if os(Windows)
    import Foundation
    @preconcurrency import WinSDK

    /// Sendable wrapper for `HANDLE` (`UnsafeMutableRawPointer`),
    /// which doesn't carry `Sendable` conformance. Win32 pipe + event
    /// handles are thread-safe to use across threads per MSDN.
    struct SendableHandle: @unchecked Sendable {
        let raw: HANDLE
    }

    enum NamedPipeIO {
        /// Default buffer size for `CreateNamedPipeW` -- 64 KiB
        /// matches the OS-side message-mode cap and is well above
        /// typical envelope sizes (a `badgeChanged` is <1 KiB).
        /// The pipe still accepts larger frames via the length-prefix
        /// framing; this is just the kernel buffer.
        static let bufferSize: Int = 65536

        /// Convert a Sprig-internal pipe name (e.g. `sprig-agent-...`)
        /// to the Win32 canonical form `\\.\pipe\sprig-agent-...`.
        /// Idempotent on already-prefixed input.
        static func canonicalPipePath(_ name: String) -> String {
            if name.hasPrefix(#"\\.\pipe\"#) {
                return name
            }
            return #"\\.\pipe\"# + name
        }

        /// Read exactly `byteCount` bytes via OVERLAPPED `ReadFile`,
        /// waiting on `[completeEvent, cancelEvent]`. Returns nil on
        /// cancel, peer-close, or unrecoverable error -- the caller
        /// interprets nil as "we're done."
        ///
        /// The completion event is manual-reset; we `ResetEvent` it
        /// before each ReadFile. The cancel event stays signaled once
        /// `close()` sets it (never re-armed), so any pending read
        /// wakes immediately after the first cancel signal.
        static func readExactlyOverlapped(
            handle: HANDLE,
            completeEvent: HANDLE,
            cancelEvent: HANDLE,
            byteCount: Int
        ) -> Data? {
            if byteCount == 0 { return Data() }
            var buffer = Data(count: byteCount)
            let success: Bool = buffer.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                var offset = 0
                while offset < byteCount {
                    let outcome = readChunk(
                        handle: handle,
                        completeEvent: completeEvent,
                        cancelEvent: cancelEvent,
                        into: base.advanced(by: offset),
                        remaining: DWORD(byteCount - offset)
                    )
                    switch outcome {
                    case let .completed(bytes): offset += Int(bytes)
                    case .teardown: return false
                    }
                }
                return true
            }
            return success ? buffer : nil
        }

        /// Outcome of an OVERLAPPED `ConnectNamedPipe` wait.
        ///
        /// `connected` — a client opened the pipe end; the caller can
        /// hand the pipe handle to a `NamedPipeTransport`.
        /// `cancelled` — the cancel event fired before any client
        /// arrived; the caller should close the pipe handle and exit
        /// its accept loop.
        /// `failed(_:)` — the wait or the `ConnectNamedPipe` call
        /// itself failed; the string carries the `GetLastError` value
        /// for diagnostics.
        enum AcceptOutcome: Equatable {
            case connected
            case cancelled
            case failed(String)
        }

        /// Wait for one client to connect to a server-side pipe
        /// instance, with cancel support.
        ///
        /// Drives `ConnectNamedPipe` in OVERLAPPED mode and waits on
        /// `[completeEvent, cancelEvent]` via `WaitForMultipleObjects`,
        /// so a `SetEvent(cancelEvent)` from another thread unblocks
        /// the call deterministically (mirrors the read-loop pattern
        /// in `readExactlyOverlapped`).
        ///
        /// `completeEvent` is manual-reset and reused across iterations
        /// of an accept loop; the helper `ResetEvent`s it before each
        /// `ConnectNamedPipe` call so the caller doesn't have to. The
        /// pipe handle stays open in every outcome — closing it is the
        /// caller's job (a `connected` outcome hands the handle to a
        /// `NamedPipeTransport` which owns it; the other outcomes leave
        /// the caller to `CloseHandle` it).
        static func acceptClient(
            on handle: HANDLE,
            completeEvent: HANDLE,
            cancelEvent: HANDLE
        ) -> AcceptOutcome {
            ResetEvent(completeEvent)
            var overlapped = OVERLAPPED()
            overlapped.hEvent = completeEvent
            let ok = ConnectNamedPipe(handle, &overlapped)
            if ok == false {
                let err = GetLastError()
                // `ERROR_PIPE_CONNECTED` is the documented "client
                // already raced in" case -- the pipe is already
                // connected and there's nothing to wait for.
                if err == ERROR_PIPE_CONNECTED {
                    return .connected
                }
                if err != ERROR_IO_PENDING {
                    return .failed("ConnectNamedPipe failed: GetLastError=\(err)")
                }
            }
            var waitHandles: [HANDLE?] = [completeEvent, cancelEvent]
            let waitResult: DWORD = waitHandles.withUnsafeMutableBufferPointer { ptr in
                WaitForMultipleObjects(DWORD(ptr.count), ptr.baseAddress, false, INFINITE)
            }
            switch waitResult {
            case WAIT_OBJECT_0:
                return .connected
            case WAIT_OBJECT_0 + 1:
                // Cancel signaled. Tear down the pending I/O so the
                // kernel doesn't keep referencing the OVERLAPPED
                // struct after we return.
                CancelIoEx(handle, &overlapped)
                var bytesTransferred: DWORD = 0
                _ = GetOverlappedResult(handle, &overlapped, &bytesTransferred, true)
                return .cancelled
            default:
                return .failed("WaitForMultipleObjects(accept) failed: result=\(waitResult)")
            }
        }

        /// Per-chunk read outcome -- factored out of
        /// `readExactlyOverlapped` so its body stays under SwiftLint's
        /// function-length cap.
        private enum ReadChunkOutcome {
            case completed(DWORD)
            case teardown
        }

        private static func readChunk(
            handle: HANDLE,
            completeEvent: HANDLE,
            cancelEvent: HANDLE,
            into base: UnsafeMutableRawPointer,
            remaining: DWORD
        ) -> ReadChunkOutcome {
            ResetEvent(completeEvent)
            var overlapped = OVERLAPPED()
            overlapped.hEvent = completeEvent
            let immediate = ReadFile(handle, base, remaining, nil, &overlapped)
            if immediate == false {
                let err = GetLastError()
                if err != ERROR_IO_PENDING {
                    return .teardown
                }
            }
            var waitHandles: [HANDLE?] = [completeEvent, cancelEvent]
            let waitResult: DWORD = waitHandles.withUnsafeMutableBufferPointer { ptr in
                WaitForMultipleObjects(DWORD(ptr.count), ptr.baseAddress, false, INFINITE)
            }
            switch waitResult {
            case WAIT_OBJECT_0:
                var bytesRead: DWORD = 0
                let ok = GetOverlappedResult(handle, &overlapped, &bytesRead, false)
                if !ok || bytesRead == 0 { return .teardown }
                return .completed(bytesRead)
            case WAIT_OBJECT_0 + 1:
                // Cancel signaled. Tear down the pending I/O so the
                // kernel doesn't keep referencing the OVERLAPPED
                // struct after we return.
                CancelIoEx(handle, &overlapped)
                var bytesRead: DWORD = 0
                _ = GetOverlappedResult(handle, &overlapped, &bytesRead, true)
                return .teardown
            default:
                return .teardown
            }
        }
    }
#endif
