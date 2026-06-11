// ForgeTestSupport.swift
//
// The canned-response ForgeHTTPClient shared by every ForgeKit suite
// (only *git* is never mocked in this repo; HTTP fakes are the
// conventional seam, mirroring AIKit's HTTPClient tests).

@testable import ForgeKit
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class FakeForgeHTTPClient: ForgeHTTPClient, @unchecked Sendable {
    struct Canned {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int = 200, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var queue: [Canned]
    private var captured: [URLRequest] = []

    /// FIFO response queue; the LAST entry repeats once the queue
    /// drains, so an "always another page" fake is a single entry.
    init(responses: [Canned]) {
        precondition(!responses.isEmpty, "at least one canned response")
        queue = responses
    }

    /// One canned response repeated for every request.
    convenience init(status: Int, body: Data) {
        self.init(responses: [Canned(status: status, body: body)])
    }

    var lastRequest: URLRequest? {
        sync { captured.last }
    }

    /// Every request seen, in order — pagination tests assert the
    /// follow-the-next-URL sequence.
    var requests: [URLRequest] {
        sync { captured }
    }

    /// Sync critical section (NSLock's lock()/unlock() are
    /// unavailable in async contexts on the snapshot toolchain).
    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func dequeue(recording request: URLRequest) -> Canned {
        sync {
            captured.append(request)
            if queue.count > 1 {
                return queue.removeFirst()
            }
            return queue[0]
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let canned = dequeue(recording: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: canned.headers
        )!
        return (canned.body, response)
    }
}
