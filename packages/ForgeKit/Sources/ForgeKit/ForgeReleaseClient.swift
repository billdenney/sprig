// ForgeReleaseClient.swift
//
// ADR 0087 — a provider-agnostic forge Release client: create a
// GitHub/GitLab Release (tag + title + notes) and upload assets. Modeled
// on `ForgeRepoBrowser` (ADR 0078): one public method dispatches on
// `ForgeProvider` to private per-provider implementations; the wire
// shapes are file-scoped Decodables; the public surface is
// provider-neutral. HTTP goes through the injected `ForgeHTTPClient`
// (NOT TransportKit — that's the IPC transport; this is forge HTTP).
//
// Auth follows the tokens-injected-never-persisted rule (ADR 0078/0081):
// the token is a parameter, never stored here. The caller (CredentialKit
// / the task window) owns storage and the publish-consent confirmation.
//
// Tier 1, portable.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What to create. Provider-neutral; the per-provider code maps these to
/// the right wire field names (GitHub `body`/`target_commitish`, GitLab
/// `description`/`ref`).
public struct CreateReleaseRequest: Sendable, Equatable {
    public let tagName: String
    /// The commit/branch the tag points at (GitHub `target_commitish`,
    /// GitLab `ref`); nil lets the forge default it.
    public let targetCommitish: String?
    public let title: String?
    public let notes: String?
    public let isDraft: Bool
    public let isPrerelease: Bool

    public init(
        tagName: String,
        targetCommitish: String? = nil,
        title: String? = nil,
        notes: String? = nil,
        isDraft: Bool = false,
        isPrerelease: Bool = false
    ) {
        self.tagName = tagName
        self.targetCommitish = targetCommitish
        self.title = title
        self.notes = notes
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
    }
}

/// A created release (provider-neutral).
public struct Release: Sendable, Equatable {
    /// Forge id — GitHub's numeric release id (as a string), GitLab's
    /// tag name (its release identity).
    public let id: String
    public let tagName: String
    /// The release's web URL, when the forge returns one.
    public let htmlURL: String?
    /// GitHub's `upload_url` asset template; nil for forges that don't
    /// use one.
    public let uploadURL: String?

    public init(id: String, tagName: String, htmlURL: String?, uploadURL: String?) {
        self.id = id
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.uploadURL = uploadURL
    }
}

/// An uploaded asset (provider-neutral).
public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: String?

    public init(name: String, downloadURL: String?) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

/// Release-specific errors (HTTP failures still surface as ``ForgeError``).
public enum ForgeReleaseError: Error, Equatable, Sendable {
    /// Release creation isn't implemented for this provider yet.
    case providerNotSupported(ForgeProvider)
    /// Binary asset upload isn't implemented for this provider yet
    /// (GitLab's two-step upload+link is a tracked follow-up).
    case assetUploadNotSupported(ForgeProvider)
    /// The created release had no asset upload URL to upload to.
    case missingUploadURL
}

/// Provider-agnostic forge Release client.
public struct ForgeReleaseClient: Sendable {
    let client: any ForgeHTTPClient

    public init(client: any ForgeHTTPClient = URLSessionForgeHTTPClient()) {
        self.client = client
    }

    /// Create a release on `provider` for `owner`/`repo`.
    public func createRelease(
        provider: ForgeProvider,
        token: String,
        owner: String,
        repo: String,
        request: CreateReleaseRequest,
        baseURL: URL? = nil
    ) async throws -> Release {
        switch provider {
        case .github:
            try await createGitHubRelease(token: token, owner: owner, repo: repo, request: request, baseURL: baseURL)
        case .gitlab:
            try await createGitLabRelease(token: token, owner: owner, repo: repo, request: request, baseURL: baseURL)
        case .bitbucket, .gitea:
            throw ForgeReleaseError.providerNotSupported(provider)
        }
    }

    /// Upload a file as a release asset. GitHub only for now (raw bytes
    /// to the release's `upload_url`); GitLab's two-step is deferred.
    public func uploadAsset(
        provider: ForgeProvider,
        token: String,
        release: Release,
        fileURL: URL,
        contentType: String? = nil
    ) async throws -> ReleaseAsset {
        switch provider {
        case .github:
            try await uploadGitHubAsset(token: token, release: release, fileURL: fileURL, contentType: contentType)
        case .gitlab, .bitbucket, .gitea:
            throw ForgeReleaseError.assetUploadNotSupported(provider)
        }
    }

    // MARK: - Shared HTTP

    /// Send `request`, classifying 401 → ``ForgeError/unauthorized`` and
    /// other non-2xx → ``ForgeError/httpStatus(_:)`` (same contract as
    /// ``ForgeRepoBrowser``).
    func sendExpectingSuccess(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await client.send(request)
        guard response.statusCode != 401 else { throw ForgeError.unauthorized }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ForgeError.httpStatus(response.statusCode)
        }
        return data
    }
}
