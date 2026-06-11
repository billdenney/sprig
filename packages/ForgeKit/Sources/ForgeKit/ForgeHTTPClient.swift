// ForgeHTTPClient.swift
//
// ADR 0078 — the HTTP transport seam ForgeKit speaks through,
// mirroring AIKit's proven `HTTPClient` shape: injectable for tests
// (only *git* is never-mocked in this repo; HTTP fakes are the
// conventional seam), `URLSession`-backed in production.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Minimal HTTP transport seam (AIKit's `HTTPClient` shape).
public protocol ForgeHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed default.
public struct URLSessionForgeHTTPClient: ForgeHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ForgeError.malformedResponse(detail: "non-HTTP response")
        }
        return (data, httpResponse)
    }
}
