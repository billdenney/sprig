// ForgeRepoBrowserTests.swift
//
// ADR 0078 — the GitHub listing client against a canned-response
// fake (only *git* is never mocked in this repo; HTTP fakes are the
// conventional seam, mirroring AIKit's HTTPClient tests). Pins the
// request shape (endpoint, auth header, query), the wire decode, and
// the typed error paths.

@testable import ForgeKit
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private final class FakeForgeHTTPClient: ForgeHTTPClient, @unchecked Sendable {
    let status: Int
    let body: Data
    private let lock = NSLock()
    private var captured: URLRequest?

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    /// Sync capture (NSLock's lock()/unlock() are unavailable in
    /// async contexts on the snapshot toolchain).
    private func capture(_ request: URLRequest) {
        lock.lock()
        captured = request
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capture(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }
}

@Suite("ForgeRepoBrowser — GitHub listing")
struct ForgeRepoBrowserTests {
    private let wireSample = Data("""
    [
      {
        "full_name": "bill/sprig",
        "clone_url": "https://github.com/bill/sprig.git",
        "ssh_url": "git@github.com:bill/sprig.git",
        "description": "Finder-first Git GUI",
        "private": false
      },
      {
        "full_name": "bill/secret-sauce",
        "clone_url": "https://github.com/bill/secret-sauce.git",
        "ssh_url": null,
        "description": null,
        "private": true
      }
    ]
    """.utf8)

    @Test("request shape: endpoint, bearer token, per_page + sort query")
    func requestShape() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: wireSample)
        _ = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .github, token: "tok123")

        let request = try #require(fake.lastRequest)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.github.com/user/repos?"))
        #expect(url.contains("per_page=100"))
        #expect(url.contains("sort=pushed"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test("the documented wire shape decodes, nulls and all")
    func decodesWire() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: wireSample)
        let repos = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .github, token: "t")

        #expect(repos == [
            ForgeRepo(
                fullName: "bill/sprig",
                cloneURL: "https://github.com/bill/sprig.git",
                sshURL: "git@github.com:bill/sprig.git",
                description: "Finder-first Git GUI",
                isPrivate: false
            ),
            ForgeRepo(
                fullName: "bill/secret-sauce",
                cloneURL: "https://github.com/bill/secret-sauce.git",
                sshURL: nil,
                description: nil,
                isPrivate: true
            )
        ])
    }

    @Test("401 is the typed unauthorized; other failures carry their status")
    func typedErrors() async throws {
        let unauthorized = ForgeRepoBrowser(
            client: FakeForgeHTTPClient(status: 401, body: Data())
        )
        await #expect(throws: ForgeError.unauthorized) {
            _ = try await unauthorized.listRepos(provider: .github, token: "expired")
        }

        let flaky = ForgeRepoBrowser(
            client: FakeForgeHTTPClient(status: 502, body: Data())
        )
        await #expect(throws: ForgeError.httpStatus(502)) {
            _ = try await flaky.listRepos(provider: .github, token: "t")
        }

        let garbage = ForgeRepoBrowser(
            client: FakeForgeHTTPClient(status: 200, body: Data("not json".utf8))
        )
        await #expect(throws: ForgeError.self) {
            _ = try await garbage.listRepos(provider: .github, token: "t")
        }
    }

    @Test("baseURL override points the request at an enterprise host")
    func baseURLOverride() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: Data("[]".utf8))
        _ = try await ForgeRepoBrowser(client: fake).listRepos(
            provider: .github,
            token: "t",
            baseURL: #require(URL(string: "https://github.example.com/api/v3"))
        )
        let url = try #require(fake.lastRequest?.url?.absoluteString)
        #expect(url.hasPrefix("https://github.example.com/api/v3/user/repos?"))
    }

    // MARK: - GitLab provider

    private var gitlabWire: Data {
        Data("""
        [
          {
            "path_with_namespace": "bill/sprig-mirror",
            "http_url_to_repo": "https://gitlab.com/bill/sprig-mirror.git",
            "ssh_url_to_repo": "git@gitlab.com:bill/sprig-mirror.git",
            "description": "mirror",
            "visibility": "public"
          },
          {
            "path_with_namespace": "bill/internal-tool",
            "http_url_to_repo": "https://gitlab.com/bill/internal-tool.git",
            "ssh_url_to_repo": null,
            "description": null,
            "visibility": "internal"
          }
        ]
        """.utf8)
    }

    @Test("GitLab request shape: /api/v4/projects with membership + bearer token")
    func gitlabRequestShape() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: gitlabWire)
        _ = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .gitlab, token: "glpat-x")

        let request = try #require(fake.lastRequest)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://gitlab.com/api/v4/projects?"))
        #expect(url.contains("membership=true"))
        #expect(url.contains("order_by=last_activity_at"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer glpat-x")
    }

    @Test("GitLab wire decodes; internal visibility maps to private; self-hosted base works")
    func gitlabDecodesWire() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: gitlabWire)
        let repos = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .gitlab, token: "t")

        #expect(repos.map(\.fullName) == ["bill/sprig-mirror", "bill/internal-tool"])
        #expect(repos[0].isPrivate == false)
        #expect(repos[1].isPrivate == true, "internal still requires auth to clone")
        #expect(repos[1].sshURL == nil)

        let hosted = FakeForgeHTTPClient(status: 200, body: Data("[]".utf8))
        _ = try await ForgeRepoBrowser(client: hosted).listRepos(
            provider: .gitlab,
            token: "t",
            baseURL: #require(URL(string: "https://git.example.com"))
        )
        let hostedURL = try #require(hosted.lastRequest?.url?.absoluteString)
        #expect(hostedURL.hasPrefix("https://git.example.com/api/v4/projects?"))
    }
}
