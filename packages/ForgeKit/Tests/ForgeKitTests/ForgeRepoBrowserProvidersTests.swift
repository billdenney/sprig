// ForgeRepoBrowserProvidersTests.swift
//
// ADR 0078 follow-up — the Bitbucket Cloud and Gitea providers.
// Pins per forge: request shape + auth scheme (Gitea's is `token`,
// NOT `Bearer` — the one that bites self-hosted users), the wire
// decode into ForgeRepo, and Bitbucket's body-`next` pagination.

@testable import ForgeKit
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("ForgeRepoBrowser — Bitbucket + Gitea providers")
struct ForgeRepoBrowserProvidersTests {
    // MARK: - Bitbucket

    private func bitbucketPage(values: [String], next: String?) -> Data {
        let nextField = next.map { "\"\($0)\"" } ?? "null"
        return Data("{\"values\": [\(values.joined(separator: ","))], \"next\": \(nextField)}".utf8)
    }

    private func bitbucketRepo(_ name: String, ssh: Bool) -> String {
        let sshLink = ssh
            ? #", {"name": "ssh", "href": "git@bitbucket.org:\#(name).git"}"#
            : ""
        return """
        {
          "full_name": "\(name)",
          "is_private": true,
          "description": null,
          "links": {
            "clone": [
              {"name": "https", "href": "https://bitbucket.org/\(name).git"}\(sshLink)
            ]
          }
        }
        """
    }

    @Test("Bitbucket request shape: /2.0/repositories with role + recency sort, bearer auth")
    func bitbucketRequestShape() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: bitbucketPage(values: [], next: nil))
        _ = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .bitbucket, token: "bb-tok")

        let request = try #require(fake.lastRequest)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.bitbucket.org/2.0/repositories?"))
        #expect(url.contains("role=member"))
        #expect(url.contains("pagelen=100"))
        #expect(url.contains("sort=-updated_on"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bb-tok")
    }

    @Test("Bitbucket decodes clone-links and follows the body next URL")
    func bitbucketDecodesAndPaginates() async throws {
        let nextURL = "https://api.bitbucket.org/2.0/repositories?role=member&page=2"
        let fake = FakeForgeHTTPClient(responses: [
            .init(body: bitbucketPage(values: [bitbucketRepo("ws/alpha", ssh: true)], next: nextURL)),
            .init(body: bitbucketPage(values: [bitbucketRepo("ws/beta", ssh: false)], next: nil))
        ])

        let repos = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .bitbucket, token: "t")

        #expect(repos.map(\.fullName) == ["ws/alpha", "ws/beta"])
        #expect(repos[0].cloneURL == "https://bitbucket.org/ws/alpha.git")
        #expect(repos[0].sshURL == "git@bitbucket.org:ws/alpha.git")
        #expect(repos[1].sshURL == nil)
        #expect(repos[0].isPrivate)
        #expect(fake.requests.count == 2)
        #expect(fake.requests[1].url?.absoluteString == nextURL)
    }

    @Test("a Bitbucket repo without an https clone link is a malformed response, not a skip")
    func bitbucketMissingHttpsLink() async throws {
        let broken = """
        {
          "full_name": "ws/broken",
          "is_private": false,
          "description": null,
          "links": {"clone": [{"name": "ssh", "href": "git@bitbucket.org:ws/broken.git"}]}
        }
        """
        let fake = FakeForgeHTTPClient(
            status: 200,
            body: bitbucketPage(values: [broken], next: nil)
        )

        do {
            _ = try await ForgeRepoBrowser(client: fake)
                .listRepos(provider: .bitbucket, token: "t")
            Issue.record("expected malformedResponse")
        } catch let ForgeError.malformedResponse(detail) {
            #expect(detail.contains("ws/broken"))
        }
    }

    // MARK: - Gitea

    private var giteaWire: Data {
        Data("""
        [
          {
            "full_name": "bill/tools",
            "clone_url": "https://gitea.com/bill/tools.git",
            "ssh_url": "git@gitea.com:bill/tools.git",
            "description": "odds and ends",
            "private": true
          }
        ]
        """.utf8)
    }

    @Test("Gitea request shape: /api/v1/user/repos with the `token` auth scheme, not Bearer")
    func giteaRequestShape() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: Data("[]".utf8))
        _ = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .gitea, token: "glt-x")

        let request = try #require(fake.lastRequest)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://gitea.com/api/v1/user/repos?"))
        #expect(url.contains("limit=50"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token glt-x")
    }

    @Test("Gitea wire decodes; self-hosted base works")
    func giteaDecodesWire() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: giteaWire)
        let repos = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .gitea, token: "t")

        #expect(repos == [
            ForgeRepo(
                fullName: "bill/tools",
                cloneURL: "https://gitea.com/bill/tools.git",
                sshURL: "git@gitea.com:bill/tools.git",
                description: "odds and ends",
                isPrivate: true
            )
        ])

        let hosted = FakeForgeHTTPClient(status: 200, body: Data("[]".utf8))
        _ = try await ForgeRepoBrowser(client: hosted).listRepos(
            provider: .gitea,
            token: "t",
            baseURL: forgeTestURL("https://code.example.org")
        )
        let hostedURL = try #require(hosted.lastRequest?.url?.absoluteString)
        #expect(hostedURL.hasPrefix("https://code.example.org/api/v1/user/repos?"))
    }
}
