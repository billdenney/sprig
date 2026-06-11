// ForgeRepoBrowser.swift
//
// Affordance 3.2 / ADR 0078 — the portable half of "browse my repos
// instead of pasting a clone URL". Given a forge token, list the
// user's repositories with their clone URLs. GitHub first; the
// provider enum is where GitLab/Bitbucket/Gitea join (ADR 0063's
// per-forge matrix).
//
// Layering (recorded in ADR 0078): TOKENS ARE INJECTED. Acquisition
// (OAuth device flow) is shell/onboarding work; storage is
// CredentialKit's platform adapters (Keychain / DPAPI / Secret
// Service — stubs today). This package never persists a token.
//
// Tier 1 portable. Pure Foundation (+ FoundationNetworking on
// non-Apple platforms). The HTTP seam mirrors AIKit's proven
// `HTTPClient` shape — injectable for tests; only *git* is
// never-mocked in this repo, HTTP fakes are conventional.

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

/// GitHub's documented `/user/repos` element shape (the fields we
/// consume). File-private: the public surface is ``ForgeRepo``.
private struct GitHubRepo: Decodable {
    let fullName: String
    let cloneUrl: String
    let sshUrl: String?
    let description: String?
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case cloneUrl = "clone_url"
        case sshUrl = "ssh_url"
        case description
        case isPrivate = "private"
    }
}

/// Lists the authenticated user's repositories.
public struct ForgeRepoBrowser: Sendable {
    private let client: any ForgeHTTPClient

    public init(client: any ForgeHTTPClient = URLSessionForgeHTTPClient()) {
        self.client = client
    }

    /// First page (100 repos, most recently pushed first) of the
    /// user's repositories. Pagination via the `Link` header is a
    /// noted follow-up — 100 covers the affordance's "pick from a
    /// list" purpose for most users.
    ///
    /// - Parameters:
    ///   - token: a personal-access/OAuth token. Never persisted here.
    ///   - baseURL: override for GitHub Enterprise (and tests).
    public func listRepos(
        provider: ForgeProvider,
        token: String,
        baseURL: URL? = nil
    ) async throws -> [ForgeRepo] {
        switch provider {
        case .github:
            try await listGitHub(token: token, baseURL: baseURL)
        }
    }

    private func listGitHub(token: String, baseURL: URL?) async throws -> [ForgeRepo] {
        let base = baseURL ?? URL(string: "https://api.github.com")!
        let endpoint = base.appendingPathComponent("user").appendingPathComponent("repos")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ForgeError.malformedResponse(detail: "unbuildable endpoint URL")
        }
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "pushed")
        ]
        guard let url = components.url else {
            throw ForgeError.malformedResponse(detail: "unbuildable endpoint URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await client.send(request)
        guard response.statusCode != 401 else { throw ForgeError.unauthorized }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ForgeError.httpStatus(response.statusCode)
        }

        do {
            return try JSONDecoder().decode([GitHubRepo].self, from: data).map {
                ForgeRepo(
                    fullName: $0.fullName,
                    cloneURL: $0.cloneUrl,
                    sshURL: $0.sshUrl,
                    description: $0.description,
                    isPrivate: $0.isPrivate
                )
            }
        } catch {
            throw ForgeError.malformedResponse(detail: String(describing: error))
        }
    }
}
