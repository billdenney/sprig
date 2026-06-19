// CreateReleaseViewModelTests.swift
//
// ADR 0087 — the publish-consent release flow: real git for the local
// annotated tag, a stub ForgeHTTPClient for the forge calls. The
// load-bearing claims: publish() refuses until prepare() (consent), the
// happy path creates the tag + release + uploads assets, and a
// pre-existing local tag is a typed refusal.

import ForgeKit
import Foundation
import GitCore
@testable import TaskWindowKit
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Minimal ForgeHTTPClient stub: a FIFO queue of (status, body),
/// repeating the last entry once drained.
private final class StubForgeHTTPClient: ForgeHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, Data)]
    private(set) var requestCount = 0

    init(_ responses: [(Int, Data)]) {
        precondition(!responses.isEmpty)
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // lock/unlock can't be called directly from an async context;
        // confine them to a synchronous closure.
        let entry = withLock { () -> (Int, Data) in
            requestCount += 1
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: entry.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (entry.1, response)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Suite("CreateReleaseViewModel — publish-consent flow (real git + stub HTTP)", .serialized)
struct CreateReleaseViewModelTests {
    private struct Fixture {
        let dir: URL
        let runner: Runner
        let head: String
    }

    private func makeRepo(_ label: String) async throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-release-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "c1"])
        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Fixture(dir: dir, runner: runner, head: head)
    }

    private let releaseJSON = Data("""
    {"id":7,"tag_name":"v1.0.0","html_url":"https://github.com/o/r/releases/tag/v1.0.0",
     "upload_url":"https://uploads.github.com/repos/o/r/releases/7/assets{?name,label}"}
    """.utf8)
    private let assetJSON = Data("""
    {"name":"a.bin","browser_download_url":"https://github.com/o/r/releases/download/v1.0.0/a.bin"}
    """.utf8)

    @Test("publish refuses until prepare() — the consent gate")
    func consentGate() async throws {
        let fixture = try await makeRepo("consent")
        let dir = fixture.dir
        let runner = fixture.runner
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "tok",
            runner: runner, releaseClient: ForgeReleaseClient(client: StubForgeHTTPClient([(201, releaseJSON)])),
            tagName: "v1.0.0"
        )
        await vm.publish()
        #expect(await vm.state.failure != nil)
        #expect(await vm.summary == nil)
    }

    @Test("prepare rejects an empty tag and otherwise builds a summary")
    func prepareSummary() async throws {
        let fixture = try await makeRepo("summary")
        let dir = fixture.dir
        let runner = fixture.runner
        let head = fixture.head
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "t", runner: runner
        )
        #expect(await vm.prepare() == nil) // empty tag

        await vm.setTagName("v1.0.0")
        await vm.setCreateTagAtCommit(head)
        await vm.setAssets([dir.appendingPathComponent("a.bin")])
        let summary = try #require(await vm.prepare())
        #expect(summary.tagName == "v1.0.0")
        #expect(summary.repository == "o/r")
        #expect(summary.willCreateTag)
        #expect(summary.assetCount == 1)
    }

    @Test("publish creates the local tag, the release, and uploads the asset")
    func publishHappyPath() async throws {
        let fixture = try await makeRepo("publish")
        let dir = fixture.dir
        let runner = fixture.runner
        let head = fixture.head
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = dir.appendingPathComponent("a.bin")
        try Data([0x01, 0x02, 0x03]).write(to: asset)
        let stub = StubForgeHTTPClient([(201, releaseJSON), (201, assetJSON)])
        let vm = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "tok",
            runner: runner, releaseClient: ForgeReleaseClient(client: stub),
            tagName: "v1.0.0", title: "Release 1.0.0", createTagAtCommit: head, assetURLs: [asset]
        )
        _ = await vm.prepare()
        await vm.publish()

        #expect(await vm.state.successValue?.tagName == "v1.0.0")
        #expect(await vm.uploadedAssets.map(\.name) == ["a.bin"])
        #expect(stub.requestCount == 2) // create release + upload asset
        // The annotated tag was created locally.
        #expect(try await TagOps(runner: runner).exists("v1.0.0"))
    }

    @Test("publish refuses when the new local tag already exists")
    func publishTagExists() async throws {
        let fixture = try await makeRepo("tagexists")
        let dir = fixture.dir
        let runner = fixture.runner
        let head = fixture.head
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await TagOps(runner: runner).createAnnotatedTag(name: "v1.0.0", message: "pre", at: head)
        let vm = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "tok",
            runner: runner, releaseClient: ForgeReleaseClient(client: StubForgeHTTPClient([(201, releaseJSON)])),
            tagName: "v1.0.0", createTagAtCommit: head
        )
        _ = await vm.prepare()
        await vm.publish()
        #expect(await vm.state.failure != nil)
    }

    /// A forge failure must leave NO local tag behind (the tag would
    /// otherwise dead-end every retry on the exists() guard).
    @Test("forge failure with createTag leaves no orphan local tag; retry is clean")
    func forgeFailureNoOrphanTag() async throws {
        let fixture = try await makeRepo("orphan")
        let dir = fixture.dir
        let runner = fixture.runner
        let head = fixture.head
        defer { try? FileManager.default.removeItem(at: dir) }
        // createRelease returns 401 → ForgeError.unauthorized.
        let vm = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "bad",
            runner: runner, releaseClient: ForgeReleaseClient(client: StubForgeHTTPClient([(401, Data())])),
            tagName: "v1.0.0", createTagAtCommit: head
        )
        _ = await vm.prepare()
        await vm.publish()
        #expect(await vm.state.failure != nil)
        #expect(await vm.createdRelease == nil)
        // No orphan tag — so a fresh attempt isn't wedged on the exists() guard.
        #expect(try await TagOps(runner: runner).exists("v1.0.0") == false)

        let retry = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "good",
            runner: runner, releaseClient: ForgeReleaseClient(client: StubForgeHTTPClient([(201, releaseJSON)])),
            tagName: "v1.0.0", createTagAtCommit: head
        )
        _ = await retry.prepare()
        await retry.publish()
        #expect(await retry.state.successValue?.tagName == "v1.0.0")
        #expect(try await TagOps(runner: runner).exists("v1.0.0"))
    }

    /// An asset-upload failure must keep the (already-published) release so
    /// a re-publish() RESUMES the remaining assets, not re-create it.
    @Test("asset failure reports partial success; re-publish resumes upload")
    func assetFailureResumes() async throws {
        let fixture = try await makeRepo("resume")
        let dir = fixture.dir
        let runner = fixture.runner
        let head = fixture.head
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = dir.appendingPathComponent("a.bin")
        try Data([0x09]).write(to: asset)
        // create release OK, first asset upload 500, second attempt 201.
        let stub = StubForgeHTTPClient([(201, releaseJSON), (500, Data()), (201, assetJSON)])
        let vm = CreateReleaseViewModel(
            repoURL: dir, provider: .github, owner: "o", repo: "r", token: "tok",
            runner: runner, releaseClient: ForgeReleaseClient(client: stub),
            tagName: "v1.0.0", createTagAtCommit: head, assetURLs: [asset]
        )
        _ = await vm.prepare()
        await vm.publish()
        // Partial: release is live, no assets yet, but it is NOT lost.
        #expect(await vm.state.failure != nil)
        #expect(await vm.createdRelease?.tagName == "v1.0.0")
        #expect(await vm.uploadedAssets.isEmpty)
        #expect(stub.requestCount == 2)

        await vm.publish() // resume — must skip createRelease, finish the asset.
        #expect(await vm.state.successValue?.tagName == "v1.0.0")
        #expect(await vm.uploadedAssets.map(\.name) == ["a.bin"])
        #expect(stub.requestCount == 3) // only the asset retry, not a second create
    }
}
