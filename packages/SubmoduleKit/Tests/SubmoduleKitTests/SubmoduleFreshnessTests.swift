import Foundation
import GitCore
@testable import SubmoduleKit
import Testing

@Suite("SubmoduleFreshnessProbe — out-of-date vs upstream-newer")
struct SubmoduleFreshnessTests {
    private struct Fixture {
        var parent: URL
        var helper: URL
    }

    /// A super-repo with one clean, up-to-date submodule. Callers
    /// mutate from here to create each freshness scenario.
    private func makeFixture() async throws -> Fixture {
        let helper = mktemp("skit-fresh-helper")
        let parent = mktemp("skit-fresh-parent")
        try mkdir(helper, parent)

        let helperRunner = Runner(defaultWorkingDirectory: helper)
        try await initRepo(runner: helperRunner, identity: "h")
        try write("c1\n", to: helper.appendingPathComponent("a.txt"))
        _ = try await helperRunner.run(["add", "a.txt"])
        _ = try await helperRunner.run(["commit", "-m", "c1"])

        let parentRunner = Runner(defaultWorkingDirectory: parent)
        try await initRepo(runner: parentRunner, identity: "p")
        try write("seed\n", to: parent.appendingPathComponent("p.txt"))
        _ = try await parentRunner.run(["add", "p.txt"])
        _ = try await parentRunner.run(["commit", "-m", "seed"])
        _ = try await parentRunner.run(allowFile + ["submodule", "add", helper.path, "sub"])
        _ = try await parentRunner.run(allowFile + ["submodule", "update", "--init"])
        _ = try await parentRunner.run(["commit", "-m", "add sub"])

        return Fixture(parent: parent.standardized, helper: helper.standardized)
    }

    @Test("clean, up-to-date submodule suggests nothing")
    func cleanSuggestsNothing() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let freshness = try await SubmoduleFreshnessProbe.probe(at: fixture.parent, runner: runner)
        let sub = try #require(freshness.first)
        #expect(sub.path == "sub")
        #expect(sub.isOutOfDate == false)
        #expect(sub.commitsBehindUpstream == 0)
        #expect(sub.shouldSuggestUpdate == false)
    }

    @Test("checkout differing from recorded pointer reports out-of-date")
    func outOfDateDetected() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.parent, fixture.helper) }
        let parentRunner = Runner(defaultWorkingDirectory: fixture.parent)

        // Commit inside the submodule so its HEAD moves ahead of the
        // super-repo's recorded pointer (`+` state). No fetch is needed
        // for this signal — it's local to the super-repo's view.
        let subWorktree = fixture.parent.appendingPathComponent("sub")
        let subRunner = Runner(defaultWorkingDirectory: subWorktree)
        _ = try await subRunner.run(["config", "user.email", "s@test"])
        _ = try await subRunner.run(["config", "user.name", "s"])
        _ = try await subRunner.run(["config", "commit.gpgsign", "false"])
        try write("local\n", to: subWorktree.appendingPathComponent("local.txt"))
        _ = try await subRunner.run(["add", "local.txt"])
        _ = try await subRunner.run(["commit", "-m", "local"])

        let freshness = try await SubmoduleFreshnessProbe.probe(at: fixture.parent, runner: parentRunner)
        let sub = try #require(freshness.first)
        #expect(sub.isOutOfDate)
        #expect(sub.shouldSuggestUpdate)
    }

    @Test("upstream gaining commits reports commitsBehindUpstream after fetch")
    func upstreamNewerDetected() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.parent, fixture.helper) }
        let parentRunner = Runner(defaultWorkingDirectory: fixture.parent)

        // The helper (the submodule's remote) gains two new commits.
        let helperRunner = Runner(defaultWorkingDirectory: fixture.helper)
        for index in 1 ... 2 {
            try write("more \(index)\n", to: fixture.helper.appendingPathComponent("m\(index).txt"))
            _ = try await helperRunner.run(["add", "m\(index).txt"])
            _ = try await helperRunner.run(["commit", "-m", "more \(index)"])
        }

        // Fetch inside the submodule so its remote-tracking ref sees the
        // new commits — the probe is read-only and never fetches itself.
        let subRunner = Runner(defaultWorkingDirectory: fixture.parent.appendingPathComponent("sub"))
        _ = try await subRunner.run(["fetch", "origin"])

        let freshness = try await SubmoduleFreshnessProbe.probe(at: fixture.parent, runner: parentRunner)
        let sub = try #require(freshness.first)
        // The super-repo's recorded pointer still matches the checkout,
        // so it is NOT out-of-date — only upstream-newer.
        #expect(sub.isOutOfDate == false)
        #expect(sub.commitsBehindUpstream == 2)
        #expect(sub.shouldSuggestUpdate)
    }

    @Test("uninitialized submodule has no upstream signal")
    func uninitializedNoUpstream() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)
        _ = try await runner.run(["submodule", "deinit", "-f", "sub"])

        let freshness = try await SubmoduleFreshnessProbe.probe(at: fixture.parent, runner: runner)
        let sub = try #require(freshness.first)
        #expect(sub.commitsBehindUpstream == nil)
    }

    @Test("shouldSuggestUpdate is a pure OR of the two signals")
    func suggestionIsOrOfSignals() {
        #expect(!SubmoduleFreshness(path: "p", isOutOfDate: false, commitsBehindUpstream: 0).shouldSuggestUpdate)
        #expect(SubmoduleFreshness(path: "p", isOutOfDate: true, commitsBehindUpstream: 0).shouldSuggestUpdate)
        #expect(SubmoduleFreshness(path: "p", isOutOfDate: false, commitsBehindUpstream: 3).shouldSuggestUpdate)
        #expect(!SubmoduleFreshness(path: "p", isOutOfDate: false, commitsBehindUpstream: nil).shouldSuggestUpdate)
    }

    // MARK: - Fixture helpers

    private let allowFile = ["-c", "protocol.file.allow=always"]

    private func mktemp(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-\(tag)-\(UUID().uuidString)")
    }

    private func mkdir(_ urls: URL...) throws {
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func initRepo(runner: Runner, identity: String) async throws {
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "\(identity)@test"])
        _ = try await runner.run(["config", "user.name", identity])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
    }

    private func cleanup(_ urls: URL?...) {
        for case let url? in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
