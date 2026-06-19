// ForgeReleaseClientTests.swift
//
// ADR 0087 — the provider-agnostic release client, against the
// FakeForgeHTTPClient (offline). Asserts the request shape sent to each
// provider and the decoded provider-neutral output.

@testable import ForgeKit
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("ForgeReleaseClient — create release + asset upload")
struct ForgeReleaseClientTests {
    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("GitHub createRelease: endpoint, bearer, JSON body, decoded release")
    func githubCreate() async throws {
        let body = Data("""
        {"id":42,"tag_name":"v1.0.0","html_url":"https://github.com/o/r/releases/tag/v1.0.0",
         "upload_url":"https://uploads.github.com/repos/o/r/releases/42/assets{?name,label}"}
        """.utf8)
        let fake = FakeForgeHTTPClient(status: 201, body: body)

        let release = try await ForgeReleaseClient(client: fake).createRelease(
            provider: .github, token: "tok", owner: "o", repo: "r",
            request: CreateReleaseRequest(tagName: "v1.0.0", title: "Release", notes: "the notes")
        )
        #expect(release.id == "42")
        #expect(release.tagName == "v1.0.0")
        #expect(release.uploadURL?.contains("uploads.github.com") == true)

        let request = try #require(fake.lastRequest)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/o/r/releases")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let json = try bodyJSON(request)
        #expect(json["tag_name"] as? String == "v1.0.0")
        #expect(json["name"] as? String == "Release")
        #expect(json["body"] as? String == "the notes")
    }

    @Test("GitLab createRelease: URL-encoded project, description field")
    func gitlabCreate() async throws {
        let body = Data("""
        {"tag_name":"v2.0.0","_links":{"self":"https://gitlab.com/o/r/-/releases/v2.0.0"}}
        """.utf8)
        let fake = FakeForgeHTTPClient(status: 201, body: body)

        let release = try await ForgeReleaseClient(client: fake).createRelease(
            provider: .gitlab, token: "t", owner: "o", repo: "r",
            request: CreateReleaseRequest(tagName: "v2.0.0", notes: "desc")
        )
        #expect(release.tagName == "v2.0.0")
        #expect(release.htmlURL?.contains("-/releases") == true)

        let request = try #require(fake.lastRequest)
        #expect(request.url?.absoluteString == "https://gitlab.com/api/v4/projects/o%2Fr/releases")
        let json = try bodyJSON(request)
        #expect(json["description"] as? String == "desc")
        #expect(json["tag_name"] as? String == "v2.0.0")
    }

    @Test("GitHub asset upload: expanded upload_url, raw bytes, content type")
    func githubAssetUpload() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("app.zip")
        let fileBytes = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02])
        try fileBytes.write(to: file)

        let respBody = Data("""
        {"name":"app.zip","browser_download_url":"https://github.com/o/r/releases/download/v1/app.zip"}
        """.utf8)
        let fake = FakeForgeHTTPClient(status: 201, body: respBody)
        let release = Release(
            id: "42", tagName: "v1", htmlURL: nil,
            uploadURL: "https://uploads.github.com/repos/o/r/releases/42/assets{?name,label}"
        )

        let asset = try await ForgeReleaseClient(client: fake).uploadAsset(
            provider: .github, token: "t", release: release, fileURL: file, contentType: "application/zip"
        )
        #expect(asset.name == "app.zip")
        #expect(asset.downloadURL?.hasSuffix("app.zip") == true)

        let request = try #require(fake.lastRequest)
        #expect(request.url?.absoluteString == "https://uploads.github.com/repos/o/r/releases/42/assets?name=app.zip")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/zip")
        #expect(request.httpBody == fileBytes)
    }

    @Test("typed errors: 401, unsupported providers, missing upload URL")
    func typedErrors() async throws {
        let req = CreateReleaseRequest(tagName: "v1")
        await #expect(throws: ForgeError.unauthorized) {
            _ = try await ForgeReleaseClient(client: FakeForgeHTTPClient(status: 401, body: Data()))
                .createRelease(provider: .github, token: "x", owner: "o", repo: "r", request: req)
        }
        await #expect(throws: ForgeReleaseError.providerNotSupported(.bitbucket)) {
            _ = try await ForgeReleaseClient(client: FakeForgeHTTPClient(status: 201, body: Data()))
                .createRelease(provider: .bitbucket, token: "t", owner: "o", repo: "r", request: req)
        }
        await #expect(throws: ForgeReleaseError.assetUploadNotSupported(.gitlab)) {
            _ = try await ForgeReleaseClient(client: FakeForgeHTTPClient(status: 201, body: Data()))
                .uploadAsset(
                    provider: .gitlab, token: "t",
                    release: Release(id: "1", tagName: "v", htmlURL: nil, uploadURL: nil),
                    fileURL: URL(fileURLWithPath: "/tmp/x")
                )
        }
        await #expect(throws: ForgeReleaseError.missingUploadURL) {
            _ = try await ForgeReleaseClient(client: FakeForgeHTTPClient(status: 201, body: Data()))
                .uploadAsset(
                    provider: .github, token: "t",
                    release: Release(id: "1", tagName: "v", htmlURL: nil, uploadURL: nil),
                    fileURL: URL(fileURLWithPath: "/tmp/x")
                )
        }
    }
}
