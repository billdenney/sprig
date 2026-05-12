// HTTPClient — minimal HTTP transport seam.
//
// Tier 1 portable. Pure Foundation. Exists so AI providers
// (OllamaProvider today, AnthropicProvider / OpenAIProvider next)
// can be tested with a canned-response stub without going through
// URLProtocol — which has cross-platform reliability gaps in
// swift-corelibs-foundation on Linux.
//
// The protocol is intentionally one method: send a URLRequest,
// get back the body bytes plus the HTTPURLResponse. Status-code
// classification, error mapping, and retry policy live in the
// provider layer above; HTTPClient is a thin transport.

import Foundation

// On Linux + Windows (swift-corelibs-foundation), URLSession lives
// in the FoundationNetworking submodule; on Apple platforms it's
// in Foundation proper. `canImport` is a capability check (not a
// behavior branch), so it's the canonical cross-platform shape and
// doesn't conflict with CLAUDE.md hard rule 2's ban on `#if os()`
// for behavior branching.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Abstract HTTP transport. Inject via provider init for
/// testability.
public protocol HTTPClient: Sendable {
    /// Execute `request` and return the body + HTTP response
    /// metadata. Throws on transport failure (network down,
    /// connection refused, cancelled task) — the provider above
    /// translates these to ``AIError``.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed default. Use this in production; tests
/// supply their own ``HTTPClient`` conformance.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// Default session is `URLSession.shared`. Callers wanting
    /// custom timeouts, proxy config, or per-request headers
    /// pass a configured session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        // Foundation only constructs `HTTPURLResponse` for HTTP/HTTPS
        // schemes, which is the only thing AIKit providers will ever
        // hit. The cast is a defense-in-depth check; in practice this
        // throw path is unreachable.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse(scheme: request.url?.scheme)
        }
        return (data, httpResponse)
    }
}

/// Transport-level errors. Distinct from ``AIError`` — providers
/// translate these (and `URLError` cases from the underlying
/// session) into the AIKit error vocabulary.
public enum HTTPClientError: Error, Equatable, Sendable {
    /// `URLSession` returned a non-`HTTPURLResponse`. In practice
    /// only reachable if a future Foundation change starts
    /// returning custom subclasses; we surface it rather than
    /// silently force-cast.
    case nonHTTPResponse(scheme: String?)
}
