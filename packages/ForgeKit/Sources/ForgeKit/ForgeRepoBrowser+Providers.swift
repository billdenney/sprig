// ForgeRepoBrowser+Providers.swift
//
// ADR 0078 — the per-forge wire code: documented endpoint, auth
// scheme, response shape, and the mapping into the provider-neutral
// ``ForgeRepo``. Each provider sorts most-recently-active first and
// pages to ``ForgeRepoBrowser/maxPages`` (Link header for GitHub /
// GitLab / Gitea, body `next` URL for Bitbucket).
//
// Decodables are file-scope private: the public surface is
// ``ForgeRepo``; these structs exist to pin each forge's documented
// JSON field names.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// GitHub's documented `/user/repos` element shape (the fields we
/// consume).
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

/// GitLab's documented `/api/v4/projects` element shape.
/// `visibility` is `public`/`internal`/`private`; both non-public
/// levels map to `isPrivate` (internal still requires auth to clone).
private struct GitLabProject: Decodable {
    let pathWithNamespace: String
    let httpUrlToRepo: String
    let sshUrlToRepo: String?
    let description: String?
    let visibility: String

    enum CodingKeys: String, CodingKey {
        case pathWithNamespace = "path_with_namespace"
        case httpUrlToRepo = "http_url_to_repo"
        case sshUrlToRepo = "ssh_url_to_repo"
        case description
        case visibility
    }
}

/// One page of Bitbucket Cloud's `/2.0/repositories` envelope —
/// Bitbucket paginates in the body (`next` URL), not the Link header.
private struct BitbucketPage: Decodable {
    let values: [BitbucketRepo]
    let next: String?
}

private struct BitbucketRepo: Decodable {
    let fullName: String
    let isPrivate: Bool
    let description: String?
    let links: BitbucketLinks

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case isPrivate = "is_private"
        case description
        case links
    }
}

private struct BitbucketLinks: Decodable {
    let clone: [BitbucketCloneLink]
}

/// `links.clone` entries carry `name` (`https` / `ssh`) + `href`.
private struct BitbucketCloneLink: Decodable {
    let name: String
    let href: String
}

/// Gitea's documented `/api/v1/user/repos` element shape (it tracks
/// GitHub's field names closely).
private struct GiteaRepo: Decodable {
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

extension ForgeRepoBrowser {
    // MARK: - GitHub

    func listGitHub(token: String, baseURL: URL?) async throws -> [ForgeRepo] {
        let base = baseURL ?? URL(string: "https://api.github.com")!
        let first = try Self.endpoint(
            base.appendingPathComponent("user").appendingPathComponent("repos"),
            query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "pushed")
            ]
        )
        let pages = try await fetchLinkPaginated(
            first: first,
            authorization: "Bearer \(token)",
            accept: "application/vnd.github+json"
        )
        return try pages.flatMap { data in
            try Self.decode([GitHubRepo].self, from: data).map {
                ForgeRepo(
                    fullName: $0.fullName,
                    cloneURL: $0.cloneUrl,
                    sshURL: $0.sshUrl,
                    description: $0.description,
                    isPrivate: $0.isPrivate
                )
            }
        }
    }

    // MARK: - GitLab

    func listGitLab(token: String, baseURL: URL?) async throws -> [ForgeRepo] {
        let base = baseURL ?? URL(string: "https://gitlab.com")!
        let first = try Self.endpoint(
            base.appendingPathComponent("api")
                .appendingPathComponent("v4")
                .appendingPathComponent("projects"),
            query: [
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "order_by", value: "last_activity_at"),
                URLQueryItem(name: "per_page", value: "100")
            ]
        )
        let pages = try await fetchLinkPaginated(
            first: first,
            authorization: "Bearer \(token)",
            accept: "application/json"
        )
        return try pages.flatMap { data in
            try Self.decode([GitLabProject].self, from: data).map {
                ForgeRepo(
                    fullName: $0.pathWithNamespace,
                    cloneURL: $0.httpUrlToRepo,
                    sshURL: $0.sshUrlToRepo,
                    description: $0.description,
                    isPrivate: $0.visibility != "public"
                )
            }
        }
    }

    // MARK: - Bitbucket Cloud

    func listBitbucket(token: String, baseURL: URL?) async throws -> [ForgeRepo] {
        let base = baseURL ?? URL(string: "https://api.bitbucket.org")!
        var next: URL? = try Self.endpoint(
            base.appendingPathComponent("2.0").appendingPathComponent("repositories"),
            query: [
                URLQueryItem(name: "role", value: "member"),
                URLQueryItem(name: "pagelen", value: "100"),
                URLQueryItem(name: "sort", value: "-updated_on")
            ]
        )
        var repos: [ForgeRepo] = []
        var pageCount = 0
        while let url = next, pageCount < Self.maxPages {
            let (data, _) = try await fetchPage(
                url: url,
                authorization: "Bearer \(token)",
                accept: "application/json"
            )
            let page = try Self.decode(BitbucketPage.self, from: data)
            repos += try page.values.map { try Self.forgeRepo(fromBitbucket: $0) }
            next = page.next.flatMap { URL(string: $0) }
            pageCount += 1
        }
        return repos
    }

    /// Bitbucket advertises clone URLs as a `links.clone` array; the
    /// `https` entry is required (every Bitbucket Cloud repo has
    /// one — its absence means we're not looking at the documented
    /// shape), `ssh` is optional.
    private static func forgeRepo(fromBitbucket repo: BitbucketRepo) throws -> ForgeRepo {
        let clone = repo.links.clone
        guard let https = clone.first(where: { $0.name == "https" })?.href else {
            throw ForgeError.malformedResponse(
                detail: "no https clone link for \(repo.fullName)"
            )
        }
        return ForgeRepo(
            fullName: repo.fullName,
            cloneURL: https,
            sshURL: clone.first { $0.name == "ssh" }?.href,
            description: repo.description,
            isPrivate: repo.isPrivate
        )
    }

    // MARK: - Gitea

    /// Gitea note: the canonical auth scheme is `Authorization:
    /// token <x>` (Bearer also works on current releases; `token` is
    /// the one documented for every version we'd meet self-hosted).
    /// `limit` is clamped server-side to the instance's
    /// MAX_RESPONSE_ITEMS (default 50), so we ask for exactly that.
    func listGitea(token: String, baseURL: URL?) async throws -> [ForgeRepo] {
        let base = baseURL ?? URL(string: "https://gitea.com")!
        let first = try Self.endpoint(
            base.appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("user")
                .appendingPathComponent("repos"),
            query: [URLQueryItem(name: "limit", value: "50")]
        )
        let pages = try await fetchLinkPaginated(
            first: first,
            authorization: "token \(token)",
            accept: "application/json"
        )
        return try pages.flatMap { data in
            try Self.decode([GiteaRepo].self, from: data).map {
                ForgeRepo(
                    fullName: $0.fullName,
                    cloneURL: $0.cloneUrl,
                    sshURL: $0.sshUrl,
                    description: $0.description,
                    isPrivate: $0.isPrivate
                )
            }
        }
    }

    // MARK: - Decode helper

    /// `JSONDecoder.decode` with the package's typed error.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ForgeError.malformedResponse(detail: String(describing: error))
        }
    }
}
