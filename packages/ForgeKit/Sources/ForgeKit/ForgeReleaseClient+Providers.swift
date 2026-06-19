// ForgeReleaseClient+Providers.swift
//
// ADR 0087 — per-provider release wire code for ``ForgeReleaseClient``.
// The public surface stays provider-neutral; the field-name drift
// (GitHub `body`/`target_commitish` vs GitLab `description`/`ref`) and
// the asset-upload drift (GitHub raw-bytes to `upload_url` vs GitLab's
// two-step upload+link) live here.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension ForgeReleaseClient {
    // MARK: - GitHub

    func createGitHubRelease(
        token: String,
        owner: String,
        repo: String,
        request: CreateReleaseRequest,
        baseURL: URL?
    ) async throws -> Release {
        let base = baseURL ?? URL(string: "https://api.github.com")!
        let url = base.appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("releases")
        let wire = GitHubReleaseRequestWire(
            tagName: request.tagName,
            targetCommitish: request.targetCommitish,
            name: request.title,
            body: request.notes,
            draft: request.isDraft,
            prerelease: request.isPrerelease
        )
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONEncoder().encode(wire)

        let data = try await sendExpectingSuccess(httpRequest)
        let decoded = try Self.decode(GitHubReleaseWire.self, from: data)
        return Release(
            id: String(decoded.id),
            tagName: decoded.tagName,
            htmlURL: decoded.htmlURL,
            uploadURL: decoded.uploadURL
        )
    }

    func uploadGitHubAsset(
        token: String,
        release: Release,
        fileURL: URL,
        contentType: String?
    ) async throws -> ReleaseAsset {
        guard let template = release.uploadURL else { throw ForgeReleaseError.missingUploadURL }
        // `upload_url` is a URI template `…/assets{?name,label}`; strip
        // the template suffix and add the real filename as `?name=`.
        let stripped = template.components(separatedBy: "{").first ?? template
        let filename = fileURL.lastPathComponent
        // `.urlQueryAllowed` permits `& = + ? #` — fine in a query *string*,
        // but as a query *value* they'd be misread as separators, corrupting
        // filenames that contain them. Remove them so they percent-encode.
        var nameAllowed = CharacterSet.urlQueryAllowed
        nameAllowed.remove(charactersIn: "&=+?#")
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? filename
        guard let url = URL(string: "\(stripped)?name=\(encodedName)") else {
            throw ForgeReleaseError.missingUploadURL
        }
        let fileData = try Data(contentsOf: fileURL)

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        httpRequest.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = fileData

        let data = try await sendExpectingSuccess(httpRequest)
        let decoded = try Self.decode(GitHubAssetWire.self, from: data)
        return ReleaseAsset(name: decoded.name, downloadURL: decoded.browserDownloadURL)
    }

    // MARK: - GitLab

    func createGitLabRelease(
        token: String,
        owner: String,
        repo: String,
        request: CreateReleaseRequest,
        baseURL: URL?
    ) async throws -> Release {
        let base = baseURL ?? URL(string: "https://gitlab.com/api/v4")!
        // GitLab's project id is the URL-encoded `owner/repo` path
        // (the `/` becomes `%2F`).
        let project = encodePathComponent("\(owner)/\(repo)")
        guard let url = URL(string: "\(base.absoluteString)/projects/\(project)/releases") else {
            throw ForgeError.malformedResponse(detail: "could not build GitLab releases URL")
        }
        let wire = GitLabReleaseRequestWire(
            tagName: request.tagName,
            ref: request.targetCommitish,
            name: request.title,
            description: request.notes
        )
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONEncoder().encode(wire)

        let data = try await sendExpectingSuccess(httpRequest)
        let decoded = try Self.decode(GitLabReleaseWire.self, from: data)
        return Release(
            id: decoded.tagName,
            tagName: decoded.tagName,
            htmlURL: decoded.links?.releaseURL,
            uploadURL: nil
        )
    }

    // MARK: - Helpers

    private func encodePathComponent(_ raw: String) -> String {
        let unreserved = CharacterSet(
            charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ForgeError.malformedResponse(detail: String(describing: error))
        }
    }
}

// MARK: - Wire shapes (file-scoped)

private struct GitHubReleaseRequestWire: Encodable {
    let tagName: String
    let targetCommitish: String?
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case targetCommitish = "target_commitish"
        case name, body, draft, prerelease
    }
}

private struct GitHubReleaseWire: Decodable {
    let id: Int
    let tagName: String
    let htmlURL: String?
    let uploadURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case uploadURL = "upload_url"
    }
}

private struct GitHubAssetWire: Decodable {
    let name: String
    let browserDownloadURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct GitLabReleaseRequestWire: Encodable {
    let tagName: String
    let ref: String?
    let name: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case ref, name, description
    }
}

private struct GitLabReleaseWire: Decodable {
    let tagName: String
    let links: GitLabReleaseLinks?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case links = "_links"
    }
}

private struct GitLabReleaseLinks: Decodable {
    let releaseURL: String?

    enum CodingKeys: String, CodingKey {
        case releaseURL = "self"
    }
}
