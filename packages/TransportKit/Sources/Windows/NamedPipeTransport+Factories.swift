// NamedPipeTransport+Factories.swift
//
// Public + test-helper factories for `NamedPipeTransport`. Split out
// of the main file to stay under SwiftLint's file_length cap.
//
// `server(pipeName:)`  -- creates a Win32 named pipe and waits for
//                          a single client via OVERLAPPED
//                          `ConnectNamedPipe`.
// `client(pipeName:)`  -- opens an existing named pipe with
//                          `FILE_FLAG_OVERLAPPED`.
// `connectedPair(...)` -- test convenience that spins up a server
//                          + client end and wires them together
//                          inside one process.

#if os(Windows)
    import Foundation
    @preconcurrency import WinSDK

    public extension NamedPipeTransport {
        /// Create the server end of a named pipe and wait for a single
        /// client to connect. The pipe is created at
        /// `\\.\pipe\<pipeName>` and stays alive for one client; for
        /// multi-client serving, wrap an accept loop around this.
        ///
        /// Throws ``TransportError/sendFailed`` carrying the Win32
        /// error code if `CreateNamedPipeW` or `ConnectNamedPipe`
        /// fails.
        static func server(pipeName: String) async throws -> NamedPipeTransport {
            let fullName = NamedPipeIO.canonicalPipePath(pipeName)
            let handle = fullName.withCString(encodedAs: UTF16.self) { wide in
                CreateNamedPipeW(
                    wide,
                    DWORD(PIPE_ACCESS_DUPLEX) | DWORD(FILE_FLAG_OVERLAPPED),
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                    1, // single instance for this MVP; multi-client wrapper above
                    DWORD(NamedPipeIO.bufferSize),
                    DWORD(NamedPipeIO.bufferSize),
                    0, // default timeout (used only by WaitNamedPipe)
                    nil // default security descriptor -- production
                    //     agent overrides with a SID-restricted DACL
                )
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else {
                throw TransportError.sendFailed(
                    reason: "CreateNamedPipeW(\(fullName)) failed: GetLastError=\(GetLastError())"
                )
            }
            try await waitForClientConnection(on: handle)
            return try NamedPipeTransport(handle: handle)
        }

        /// Connect to an existing named pipe as a client. The pipe at
        /// `\\.\pipe\<pipeName>` must already exist (i.e. some other
        /// process has called ``server(pipeName:)`` or equivalent).
        ///
        /// Throws ``TransportError/sendFailed`` if `CreateFileW`
        /// fails -- usual case is `ERROR_FILE_NOT_FOUND` (no server)
        /// or `ERROR_PIPE_BUSY` (server saturated; caller should
        /// `WaitNamedPipe` + retry).
        static func client(pipeName: String) async throws -> NamedPipeTransport {
            let fullName = NamedPipeIO.canonicalPipePath(pipeName)
            let handle = fullName.withCString(encodedAs: UTF16.self) { wide in
                CreateFileW(
                    wide,
                    DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                    0, // no sharing -- one client per server instance
                    nil,
                    DWORD(OPEN_EXISTING),
                    DWORD(FILE_FLAG_OVERLAPPED),
                    nil
                )
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else {
                throw TransportError.sendFailed(
                    reason: "CreateFileW(\(fullName)) failed: GetLastError=\(GetLastError())"
                )
            }
            return try NamedPipeTransport(handle: handle)
        }

        /// Test convenience: spin up a server end, connect a client
        /// end to it, return both wired together. Uses a UUID-suffixed
        /// pipe name so concurrent test runs don't collide.
        static func connectedPair(
            pipeName: String = "sprig-test-\(UUID().uuidString)"
        ) async throws -> (server: NamedPipeTransport, client: NamedPipeTransport) {
            async let serverEnd = server(pipeName: pipeName)
            // Tiny delay so the server's ConnectNamedPipe call is
            // posted before the client's CreateFileW races in.
            try? await Task.sleep(nanoseconds: 50_000_000)
            let clientEnd = try await client(pipeName: pipeName)
            return try await (serverEnd, clientEnd)
        }

        /// Wait for a client to connect to the server-side pipe.
        /// Uses OVERLAPPED `ConnectNamedPipe` with a one-shot event,
        /// run on GCD's global queue so the cooperative pool stays
        /// unblocked.
        private static func waitForClientConnection(on handle: HANDLE) async throws {
            guard let connectEvent = CreateEventW(nil, true, false, nil) else {
                CloseHandle(handle)
                throw TransportError.sendFailed(
                    reason: "CreateEventW(connect) failed: GetLastError=\(GetLastError())"
                )
            }
            defer { CloseHandle(connectEvent) }

            let pipe = SendableHandle(raw: handle)
            let ev = SendableHandle(raw: connectEvent)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var ov = OVERLAPPED()
                    ov.hEvent = ev.raw
                    let ok = ConnectNamedPipe(pipe.raw, &ov)
                    if ok == false {
                        let err = GetLastError()
                        if err == ERROR_PIPE_CONNECTED {
                            cont.resume()
                            return
                        }
                        if err != ERROR_IO_PENDING {
                            CloseHandle(pipe.raw)
                            cont.resume(throwing: TransportError.sendFailed(
                                reason: "ConnectNamedPipe failed: GetLastError=\(err)"
                            ))
                            return
                        }
                    }
                    let waitResult = WaitForSingleObject(ev.raw, INFINITE)
                    if waitResult != WAIT_OBJECT_0 {
                        CloseHandle(pipe.raw)
                        cont.resume(throwing: TransportError.sendFailed(
                            reason: "WaitForSingleObject(connect) failed: result=\(waitResult)"
                        ))
                        return
                    }
                    cont.resume()
                }
            }
        }
    }
#endif
