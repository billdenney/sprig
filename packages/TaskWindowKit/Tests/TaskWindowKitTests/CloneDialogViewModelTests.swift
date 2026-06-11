// CloneDialogViewModelTests.swift
//
// Integration tests for CloneDialogViewModel against a real `git clone`
// invocation. CLAUDE.md: "Never mock the git binary in integration
// tests." Each test stands up a bare fixture repo to act as the
// upstream, runs the VM, and verifies the resulting cloned worktree.

import ForgeKit
import Foundation
import GitCore
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import TaskWindowKit
import Testing

@Suite("CloneDialogViewModel — integration against real git")
struct CloneDialogViewModelTests {
    // MARK: - Fixture support

    /// Self-cleaning bundle of temp dirs produced by ``makeBareUpstream``.
    /// Callers `cleanup(_:)` both URLs to fully tear down the fixture
    /// without touching anything outside the test's allocated temp
    /// space.
    private struct BareUpstreamFixture {
        /// Parent dir holding the bare repo (`<parent>/upstream.git`).
        /// Safe to `removeItem(at:)` — never the system temp root.
        let upstreamParent: URL

        /// Seed worktree the bare repo was cloned from. Independent
        /// from `upstreamParent`; cleanup must hit both.
        let seedDir: URL

        /// String form of `<upstreamParent>/upstream.git` to hand to
        /// `git clone` as the source URL.
        let sourcePath: String
    }

    /// Build a bare repo at an isolated temp path that has one commit.
    private func makeBareUpstream() async throws -> BareUpstreamFixture {
        let upstreamParent = try makeTempDir(tag: "upstream-parent")
        let upstreamDir = upstreamParent.appendingPathComponent("upstream.git")
        let seedDir = try makeTempDir(tag: "seed")

        // Build a normal repo with one commit, then bare-clone it into
        // upstreamDir. Bare so cloning into a working-tree dir is
        // representative of pulling from a remote.
        let seedRunner = Runner(defaultWorkingDirectory: seedDir)
        _ = try await seedRunner.run(["init", "-b", "main"])
        _ = try await seedRunner.run(["config", "user.email", "seed@sprig.app"])
        _ = try await seedRunner.run(["config", "user.name", "Seed"])
        _ = try await seedRunner.run(["config", "commit.gpgsign", "false"])
        try Data("hello\n".utf8).write(to: seedDir.appendingPathComponent("a.txt"))
        _ = try await seedRunner.run(["add", "a.txt"])
        _ = try await seedRunner.run(["commit", "-m", "seed"])

        // Bare-clone runs from the upstreamParent so the bare repo
        // lands at upstreamParent/upstream.git (an isolated test dir,
        // NOT the system temp root — that would let cleanup race
        // against every other parallel test's fixtures).
        let bareRunner = Runner(defaultWorkingDirectory: upstreamParent)
        _ = try await bareRunner.run([
            "clone", "--bare", seedDir.path, "upstream.git"
        ])

        return BareUpstreamFixture(
            upstreamParent: upstreamParent,
            seedDir: seedDir,
            sourcePath: upstreamDir.path
        )
    }

    private func makeTempDir(tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-clone-vm-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - CloneRequest validation (no git invocation)

    @Test("CloneRequest validation: empty URL surfaces a hint")
    func validationEmptyURL() {
        let req = CloneRequest(sourceURL: "", targetDirectory: "/tmp/dest")
        #expect(req.validationError == "Enter a repository URL.")
        #expect(req.isReady == false)
    }

    @Test("CloneRequest validation: empty target dir surfaces a hint")
    func validationEmptyTarget() {
        let req = CloneRequest(sourceURL: "git@example.com:x.git", targetDirectory: "")
        #expect(req.validationError == "Choose a target directory.")
    }

    @Test("CloneRequest validation: zero / negative shallow depth rejected")
    func validationInvalidDepth() {
        let req = CloneRequest(
            sourceURL: "git@example.com:x.git",
            targetDirectory: "/tmp/dest",
            depth: 0
        )
        #expect(req.validationError == "Shallow-clone depth must be a positive integer.")
    }

    @Test("CloneRequest validation: well-formed request is ready")
    func validationReady() {
        let req = CloneRequest(
            sourceURL: "git@example.com:x.git",
            targetDirectory: "/tmp/dest"
        )
        #expect(req.validationError == nil)
        #expect(req.isReady)
    }

    @Test("CloneRequest gitArguments: builds expected argv")
    func argvDefault() {
        let req = CloneRequest(
            sourceURL: "git@example.com:x.git",
            targetDirectory: "/tmp/dest"
        )
        let argv = req.gitArguments()
        #expect(argv == [
            "clone",
            "--recurse-submodules",
            "git@example.com:x.git",
            "/tmp/dest"
        ])
    }

    @Test("CloneRequest gitArguments: respects recurseSubmodules + depth")
    func argvWithFlags() {
        let req = CloneRequest(
            sourceURL: "  git@example.com:x.git  ",
            targetDirectory: "  /tmp/dest  ",
            recurseSubmodules: false,
            depth: 5
        )
        let argv = req.gitArguments()
        #expect(argv == [
            "clone",
            "--depth", "5",
            "git@example.com:x.git",
            "/tmp/dest"
        ])
    }

    // MARK: - End-to-end clone

    @Test("clone() against a real bare upstream lands in .success with the new worktree path")
    func cloneSucceeds() async throws {
        let fixture = try await makeBareUpstream()
        let parentDir = try makeTempDir(tag: "parent")
        defer { cleanup(fixture.upstreamParent, fixture.seedDir, parentDir) }

        let targetPath = parentDir.appendingPathComponent("cloned").path
        let request = CloneRequest(sourceURL: fixture.sourcePath, targetDirectory: targetPath)
        let runner = Runner(defaultWorkingDirectory: parentDir)
        let vm = CloneDialogViewModel(request: request, runner: runner)

        await vm.clone()

        let state = await vm.state
        if case let .success(url) = state {
            #expect(url.standardized.path == URL(fileURLWithPath: targetPath).standardized.path)
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("a.txt").path))
        } else {
            Issue.record("expected .success, got \(state)")
        }
    }

    @Test("clone() against a bogus URL lands in .failure with a description")
    func cloneFailsOnBogusURL() async throws {
        let parentDir = try makeTempDir(tag: "bogus")
        defer { cleanup(parentDir) }

        let targetPath = parentDir.appendingPathComponent("cloned").path
        let request = CloneRequest(
            sourceURL: "/this/path/definitely/does/not/exist.git",
            targetDirectory: targetPath
        )
        let runner = Runner(defaultWorkingDirectory: parentDir)
        let vm = CloneDialogViewModel(request: request, runner: runner)

        await vm.clone()

        let state = await vm.state
        if case let .failure(failure) = state {
            #expect(!failure.description.isEmpty)
            #expect(failure.underlyingTypeName?.contains("GitError") == true)
        } else {
            Issue.record("expected .failure, got \(state)")
        }
    }

    @Test("clone() pre-flights validation and lands in .failure without spawning git")
    func cloneFailsValidationBeforeGit() async throws {
        let parentDir = try makeTempDir(tag: "noargs")
        defer { cleanup(parentDir) }

        let request = CloneRequest(sourceURL: "", targetDirectory: "")
        let runner = Runner(defaultWorkingDirectory: parentDir)
        let vm = CloneDialogViewModel(request: request, runner: runner)

        await vm.clone()

        let state = await vm.state
        if case let .failure(failure) = state {
            // The first validation-error wins per the VM's ordering.
            #expect(failure.description == "Enter a repository URL.")
            #expect(failure.underlyingTypeName == nil)
        } else {
            Issue.record("expected validation .failure, got \(state)")
        }
    }

    // MARK: - State machine

    @Test("update(_:) replaces the request without disturbing state")
    func updateMutatesRequestOnly() async throws {
        let parentDir = try makeTempDir(tag: "update")
        defer { cleanup(parentDir) }

        let runner = Runner(defaultWorkingDirectory: parentDir)
        let vm = CloneDialogViewModel(runner: runner)
        let before = await vm.state
        #expect(before == .idle)

        let req = CloneRequest(sourceURL: "x", targetDirectory: "y")
        await vm.update(req)
        let after = await vm.state
        let read = await vm.request
        #expect(after == .idle)
        #expect(read == req)
    }

    @Test("reset() returns to .idle after a terminal state")
    func resetAfterTerminal() async throws {
        let parentDir = try makeTempDir(tag: "reset")
        defer { cleanup(parentDir) }

        let request = CloneRequest(sourceURL: "", targetDirectory: "")
        let runner = Runner(defaultWorkingDirectory: parentDir)
        let vm = CloneDialogViewModel(request: request, runner: runner)

        await vm.clone() // → .failure(validation)
        let terminal = await vm.state
        #expect(terminal.isTerminal)

        await vm.reset()
        let final = await vm.state
        #expect(final == .idle)
    }
}

// MARK: - Forge browse (affordance 3.2, ADR 0078)

private struct CannedForgeClient: ForgeHTTPClient {
    let status: Int
    let body: Data

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!)
    }
}

extension CloneDialogViewModelTests {
    @Test("browseRepos populates results; selectBrowsed fills source + seeds target")
    func browseAndSelect() async throws {
        let wire = Data("""
        [{"full_name": "bill/sprig", "clone_url": "https://github.com/bill/sprig.git",
          "ssh_url": null, "description": null, "private": false}]
        """.utf8)
        let vm = CloneDialogViewModel(
            request: CloneRequest(sourceURL: "", targetDirectory: ""),
            runner: Runner()
        )
        let browser = ForgeRepoBrowser(client: CannedForgeClient(status: 200, body: wire))

        await vm.browseRepos(provider: .github, token: "t", browser: browser)
        let results = await vm.browseResults
        #expect(await vm.browseError == nil)
        #expect(results.map(\.fullName) == ["bill/sprig"])

        try await vm.selectBrowsed(#require(results.first))
        #expect(await vm.request.sourceURL == "https://github.com/bill/sprig.git")
        #expect(await vm.request.targetDirectory == "sprig", "repo name seeds the empty target")

        // A user-typed target is never clobbered.
        var edited = await vm.request
        edited.targetDirectory = "my-dir"
        await vm.update(edited)
        try await vm.selectBrowsed(#require(results.first))
        #expect(await vm.request.targetDirectory == "my-dir")
    }

    @Test("an expired token surfaces the typed unauthorized error without touching state")
    func browseUnauthorized() async {
        let vm = CloneDialogViewModel(
            request: CloneRequest(sourceURL: "", targetDirectory: ""),
            runner: Runner()
        )
        let browser = ForgeRepoBrowser(client: CannedForgeClient(status: 401, body: Data()))

        await vm.browseRepos(provider: .github, token: "expired", browser: browser)
        #expect(await vm.browseError == .unauthorized)
        #expect(await vm.browseResults.isEmpty)
        #expect(await vm.state == .idle, "browsing never clobbers the clone lifecycle")
    }
}
