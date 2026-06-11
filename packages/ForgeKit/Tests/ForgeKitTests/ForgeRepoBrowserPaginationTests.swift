// ForgeRepoBrowserPaginationTests.swift
//
// ADR 0078 follow-up — pagination. Pins: the RFC 5988 Link parser,
// the follow-the-absolute-next-URL loop (auth preserved across
// pages), the explicit maxPages cap, and that GitLab rides the same
// shared path.

@testable import ForgeKit
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("ForgeRepoBrowser — pagination")
struct ForgeRepoBrowserPaginationTests {
    private func githubRepoJSON(_ name: String) -> String {
        """
        {
          "full_name": "\(name)",
          "clone_url": "https://github.com/\(name).git",
          "ssh_url": null,
          "description": null,
          "private": false
        }
        """
    }

    @Test("Link parser: picks rel=next among entries; quotes and spacing optional")
    func linkParserPicksNext() {
        let header = #"<https://x.test/a?page=1>; rel="prev", <https://x.test/a?page=3>; rel="next""#
        #expect(
            ForgeRepoBrowser.nextLink(inLinkHeader: header)
                == URL(string: "https://x.test/a?page=3")
        )
        let unquoted = "<https://x.test/b?page=2>;rel=next"
        #expect(
            ForgeRepoBrowser.nextLink(inLinkHeader: unquoted)
                == URL(string: "https://x.test/b?page=2")
        )
    }

    @Test("Link parser: no next entry (or garbage) means no next page")
    func linkParserFailsClosed() {
        #expect(ForgeRepoBrowser.nextLink(inLinkHeader: #"<https://x.test/a>; rel="prev""#) == nil)
        #expect(ForgeRepoBrowser.nextLink(inLinkHeader: "complete garbage") == nil)
        #expect(ForgeRepoBrowser.nextLink(inLinkHeader: "") == nil)
    }

    @Test("GitHub: follows the absolute next URL, keeps auth, concatenates pages in order")
    func githubTwoPages() async throws {
        let nextURL = "https://api.github.com/user/repos?per_page=100&sort=pushed&page=2"
        let fake = FakeForgeHTTPClient(responses: [
            .init(
                body: Data("[\(githubRepoJSON("a/one"))]".utf8),
                headers: ["Link": "<\(nextURL)>; rel=\"next\""]
            ),
            .init(body: Data("[\(githubRepoJSON("a/two"))]".utf8))
        ])

        let repos = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .github, token: "tok")

        #expect(repos.map(\.fullName) == ["a/one", "a/two"])
        let requests = fake.requests
        #expect(requests.count == 2)
        #expect(requests[1].url?.absoluteString == nextURL)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        }
    }

    @Test("the page cap is exactly maxPages, even when the forge always advertises more")
    func pageCapStopsRunawayPagination() async throws {
        let always = FakeForgeHTTPClient(responses: [
            .init(
                body: Data("[\(githubRepoJSON("a/again"))]".utf8),
                headers: ["Link": #"<https://api.github.com/user/repos?page=2>; rel="next""#]
            )
        ])

        let repos = try await ForgeRepoBrowser(client: always)
            .listRepos(provider: .github, token: "t")

        #expect(repos.count == ForgeRepoBrowser.maxPages)
        #expect(always.requests.count == ForgeRepoBrowser.maxPages)
    }

    @Test("GitLab rides the same Link-header path")
    func gitlabTwoPages() async throws {
        let project = """
        {
          "path_with_namespace": "g/proj",
          "http_url_to_repo": "https://gitlab.com/g/proj.git",
          "ssh_url_to_repo": null,
          "description": null,
          "visibility": "private"
        }
        """
        let nextURL = "https://gitlab.com/api/v4/projects?membership=true&page=2"
        let fake = FakeForgeHTTPClient(responses: [
            .init(body: Data("[\(project)]".utf8), headers: ["Link": "<\(nextURL)>; rel=\"next\""]),
            .init(body: Data("[\(project)]".utf8))
        ])

        let repos = try await ForgeRepoBrowser(client: fake)
            .listRepos(provider: .gitlab, token: "t")

        #expect(repos.count == 2)
        #expect(fake.requests.count == 2)
        #expect(fake.requests[1].url?.absoluteString == nextURL)
    }
}
