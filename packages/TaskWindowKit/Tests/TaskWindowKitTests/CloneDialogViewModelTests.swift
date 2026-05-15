// CloneDialogViewModelTests.swift
//
// Integration tests for CloneDialogViewModel against a real `git clone`
// invocation. CLAUDE.md: "Never mock the git binary in integration
// tests." Each test stands up a bare fixture repo to act as the
// upstream, runs the VM, and verifies the resulting cloned worktree.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("CloneDialogViewModel — integration against real git")
struct CloneDialogViewModelTests {
    // MARK: - Fixture support

    /// Build a bare repo at a temp path that has one commit. Returns
    /// (bareRepoURL, sourceURL-string-to-clone-from). The clone source
    /// is the bare repo's filesystem path.
    private func makeBareUpstream() async throws -> (URL, String) {
        let upstreamDir = try makeTempDir(tag: "upstream")
        let seedDir = try makeTempDir(tag: "seed")

        // Build a normal repo with one commit, then bare-clone into
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

        let bareRunner = Runner(defaultWorkingDirectory: upstreamDir.deletingLastPathComponent())
        _ = try await bareRunner.run([
            "clone", "--bare", seedDir.path, upstreamDir.lastPathComponent
        ])

        return (upstreamDir, upstreamDir.path)
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
        let (bareURL, sourceURL) = try await makeBareUpstream()
        let parentDir = try makeTempDir(tag: "parent")
        defer { cleanup(bareURL, parentDir, bareURL.deletingLastPathComponent()) }

        let targetPath = parentDir.appendingPathComponent("cloned").path
        let request = CloneRequest(sourceURL: sourceURL, targetDirectory: targetPath)
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
