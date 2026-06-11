// ForgeRepoBrowser.swift
//
// Affordance 3.2 / ADR 0078 — the portable half of "browse my repos
// instead of pasting a clone URL". Given a forge token, list the
// user's repositories with their clone URLs across GitHub, GitLab,
// Bitbucket, and Gitea (ADR 0063's per-forge matrix).
//
// Layering (recorded in ADR 0078): TOKENS ARE INJECTED. Acquisition
// (OAuth device flow) is shell/onboarding work; storage is
// CredentialKit's platform adapters (Keychain / DPAPI / Secret
// Service — stubs today). This package never persists a token.
//
// Pagination: every provider is paginated to ``ForgeRepoBrowser/maxPages``
// (an explicit cap, not a silent one — see `listRepos`). GitHub,
// GitLab, and Gitea advertise the next page via the RFC 5988 `Link`
// header; Bitbucket carries a `next` URL in the response body. The
// per-provider wire code lives in ForgeRepoBrowser+Providers.swift.
//
// Tier 1 portable. Pure Foundation (+ FoundationNetworking on
// non-Apple platforms).

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One repository the user can clone, provider-neutral.
public struct ForgeRepo: Sendable, Equatable {
    /// "owner/name".
    public let fullName: String
    /// HTTPS clone URL.
    public let cloneURL: String
    /// SSH clone URL when the forge advertises one.
    public let sshURL: String?
    public let description: String?
    public let isPrivate: Bool

    public init(
        fullName: String,
        cloneURL: String,
        sshURL: String?,
        description: String?,
        isPrivate: Bool
    ) {
        self.fullName = fullName
        self.cloneURL = cloneURL
        self.sshURL = sshURL
        self.description = description
        self.isPrivate = isPrivate
    }
}

/// Supported forges. Raw values are wire-stable (preferences,
/// `sprigctl` flags).
public enum ForgeProvider: String, Sendable, CaseIterable {
    case github
    case gitlab
    case bitbucket
    case gitea
}

/// Typed failures the UI can word.
public enum ForgeError: Error, Equatable, Sendable {
    /// 401 — the token is missing scopes, expired, or revoked.
    case unauthorized
    /// Any other non-2xx, with the status for diagnostics.
    case httpStatus(Int)
    /// The body didn't parse as the forge's documented shape.
    case malformedResponse(detail: String)
}

/// Lists the authenticated user's repositories.
public struct ForgeRepoBrowser: Sendable {
    /// Hard page cap per listing. With 100-per-page providers that is
    /// ~1000 repositories, most recently active first — an explicit
    /// ceiling for the pick-from-list affordance, not a silent
    /// truncation (documented on ``listRepos(provider:token:baseURL:)``
    /// and in ADR 0078).
    static let maxPages = 10

    let client: any ForgeHTTPClient

    public init(client: any ForgeHTTPClient = URLSessionForgeHTTPClient()) {
        self.client = client
    }

    /// The user's repositories, most recently active first, across
    /// up to ``maxPages`` pages (~1000 repos on 100-per-page forges).
    /// Repositories beyond the cap are not fetched — the affordance
    /// is "pick from a list", and every provider sorts
    /// recently-active-first, so the tail is the least likely pick.
    ///
    /// - Parameters:
    ///   - token: a personal-access/OAuth token. Never persisted here.
    ///   - baseURL: override for self-hosted instances (GitHub
    ///     Enterprise, self-managed GitLab, Gitea) and tests.
    public func listRepos(
        provider: ForgeProvider,
        token: String,
        baseURL: URL? = nil
    ) async throws -> [ForgeRepo] {
        switch provider {
        case .github:
            try await listGitHub(token: token, baseURL: baseURL)
        case .gitlab:
            try await listGitLab(token: token, baseURL: baseURL)
        case .bitbucket:
            try await listBitbucket(token: token, baseURL: baseURL)
        case .gitea:
            try await listGitea(token: token, baseURL: baseURL)
        }
    }

    // MARK: - Shared wire core

    /// One authenticated GET + status classification: 401 →
    /// ``ForgeError/unauthorized``, other non-2xx →
    /// ``ForgeError/httpStatus(_:)``.
    ///
    /// - Parameter authorization: the full `Authorization` header
    ///   value — `Bearer <token>` on GitHub/GitLab/Bitbucket,
    ///   `token <token>` on Gitea (its documented canonical scheme).
    func fetchPage(
        url: URL,
        authorization: String,
        accept: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")

        let (data, response) = try await client.send(request)
        guard response.statusCode != 401 else { throw ForgeError.unauthorized }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ForgeError.httpStatus(response.statusCode)
        }
        return (data, response)
    }

    /// Follow RFC 5988 `Link: <…>; rel="next"` pagination (GitHub,
    /// GitLab, Gitea) from `first`, collecting every page's body up
    /// to ``maxPages``.
    func fetchLinkPaginated(
        first: URL,
        authorization: String,
        accept: String
    ) async throws -> [Data] {
        var pages: [Data] = []
        var next: URL? = first
        while let url = next, pages.count < Self.maxPages {
            let (data, response) = try await fetchPage(
                url: url,
                authorization: authorization,
                accept: accept
            )
            pages.append(data)
            next = Self.nextLink(from: response)
        }
        return pages
    }

    /// Compose an endpoint URL from a base path + query items.
    static func endpoint(_ base: URL, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ForgeError.malformedResponse(detail: "unbuildable endpoint URL")
        }
        components.queryItems = query
        guard let url = components.url else {
            throw ForgeError.malformedResponse(detail: "unbuildable endpoint URL")
        }
        return url
    }

    // MARK: - Link header parsing

    /// The `rel="next"` target from a response's `Link` header, or
    /// nil when there is no next page (or no parseable header —
    /// pagination fails *closed* to "what we already have").
    static func nextLink(from response: HTTPURLResponse) -> URL? {
        // Case-insensitive header lookup: corelibs-foundation's
        // `allHeaderFields` preserves the wire casing.
        let raw = response.allHeaderFields.first { key, _ in
            String(describing: key).lowercased() == "link"
        }?.value
        guard let header = raw as? String else { return nil }
        return nextLink(inLinkHeader: header)
    }

    /// Parse `<url1>; rel="prev", <url2>; rel="next"` (quotes and
    /// spacing optional per RFC 5988 relaxations seen in the wild).
    static func nextLink(inLinkHeader header: String) -> URL? {
        for entry in header.split(separator: ",") {
            let segments = entry.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = segments.first,
                  target.hasPrefix("<"), target.hasSuffix(">")
            else { continue }
            let isNext = segments.dropFirst().contains { segment in
                segment.lowercased()
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: " ", with: "") == "rel=next"
            }
            if isNext {
                return URL(string: String(target.dropFirst().dropLast()))
            }
        }
        return nil
    }
}
