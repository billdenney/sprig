import Foundation
@testable import GitCore
import Testing

@Suite("RepoDiscovery")
struct RepoDiscoveryTests {
    // MARK: - filesystem builder helpers

    /// Build a tempdir tree from a hierarchical description. Used by every
    /// test below so the tree shape is visible in the test source rather
    /// than scattered across createDirectory + write calls.
    ///
    /// Special leaf names: `.git/` produces a `.git` directory, while
    /// `.git@FILE` produces a `.git` file (used by submodules and linked
    /// worktrees). Anything else is a regular file.
    private indirect enum Node {
        case dir(String, [Node])
        case repo(String) // shorthand for .dir(name, [.dir(".git", [])])
        case repoFile(String) // shorthand for a `.git` file (submodule-style)
        case file(String)
    }

    private func build(_ root: URL, _ nodes: [Node]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try realize(nodes, in: root)
    }

    private func realize(_ nodes: [Node], in parent: URL) throws {
        for node in nodes {
            switch node {
            case let .dir(name, children):
                let dir = parent.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try realize(children, in: dir)
            case let .repo(name):
                let dir = parent.appendingPathComponent(name)
                let dotGit = dir.appendingPathComponent(".git")
                try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
            case let .repoFile(name):
                let dir = parent.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("gitdir: ../.git/modules/x\n".utf8)
                    .write(to: dir.appendingPathComponent(".git"))
            case let .file(name):
                try Data("placeholder\n".utf8).write(to: parent.appendingPathComponent(name))
            }
        }
    }

    private func tempRoot(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-discovery-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - tests

    @Test("scan finds a repo at the root itself")
    func findsRootRepo() throws {
        let root = try tempRoot("root-repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [.dir(".git", [])])

        let repos = RepoDiscovery.scan(root: root)
        #expect(repos == [root.standardizedFileURL])
    }

    @Test("scan finds repos one level down")
    func findsImmediateChildren() throws {
        let root = try tempRoot("level-1")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .repo("alpha"),
            .repo("beta"),
            .dir("not-a-repo", [.file("README.md")])
        ])

        let repos = RepoDiscovery.scan(root: root).map(\.lastPathComponent)
        #expect(repos.sorted() == ["alpha", "beta"])
    }

    @Test("scan does NOT descend into a discovered repo")
    func doesNotDescendIntoRepo() throws {
        let root = try tempRoot("nested-stop")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .dir("outer", [
                .dir(".git", []),
                .repo("inner") // would-be inner repo; we should NOT find it
            ])
        ])

        let repos = RepoDiscovery.scan(root: root).map(\.lastPathComponent)
        #expect(repos == ["outer"])
    }

    @Test("scan recognizes a repo whose .git is a file (submodule / worktree)")
    func recognizesGitFileMarker() throws {
        let root = try tempRoot("file-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [.repoFile("submod")])

        let repos = RepoDiscovery.scan(root: root).map(\.lastPathComponent)
        #expect(repos == ["submod"])
    }

    @Test("maxDepth=0 only checks the root itself")
    func maxDepthZeroRootOnly() throws {
        let root = try tempRoot("depth-0")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [.repo("nested")])

        // Root has no .git itself; depth 0 means we never descend.
        let repos = RepoDiscovery.scan(
            root: root,
            options: RepoDiscovery.Options(maxDepth: 0)
        )
        #expect(repos.isEmpty)
    }

    @Test("maxDepth limits how far down the walker recurses")
    func maxDepthLimits() throws {
        let root = try tempRoot("depth-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .dir("a", [
                .dir("b", [
                    .dir("c", [
                        .repo("deep")
                    ])
                ])
            ])
        ])

        // depth 3: root → a → b → c. Repo `deep` lives at level 4 from root,
        // so it's out of reach.
        let shallow = RepoDiscovery.scan(
            root: root,
            options: RepoDiscovery.Options(maxDepth: 3)
        )
        #expect(shallow.isEmpty)

        let deep = RepoDiscovery.scan(
            root: root,
            options: RepoDiscovery.Options(maxDepth: 5)
        )
        #expect(deep.map(\.lastPathComponent) == ["deep"])
    }

    @Test("hidden directories are skipped by default")
    func skipsHiddenByDefault() throws {
        let root = try tempRoot("hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .dir(".cache", [.repo("buried")]),
            .repo("visible")
        ])

        let repos = RepoDiscovery.scan(root: root).map(\.lastPathComponent)
        #expect(repos == ["visible"])
    }

    @Test("includeHidden=true descends into dot-directories")
    func canIncludeHidden() throws {
        let root = try tempRoot("hidden-on")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .dir(".cache", [.repo("buried")]),
            .repo("visible")
        ])

        let repos = RepoDiscovery.scan(
            root: root,
            options: RepoDiscovery.Options(includeHidden: true)
        ).map(\.lastPathComponent).sorted()
        #expect(repos == ["buried", "visible"])
    }

    @Test("default skipNames include node_modules and .build")
    func skipsBuiltinNoiseDirs() throws {
        let root = try tempRoot("skip-defaults")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .dir("node_modules", [.repo("ghost")]),
            .dir(".build", [.repo("phantom")]),
            .repo("real")
        ])

        let repos = RepoDiscovery.scan(root: root).map(\.lastPathComponent)
        #expect(repos == ["real"])
    }

    @Test("custom skipNames replace the default set")
    func customSkipNames() throws {
        let root = try tempRoot("skip-custom")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, [
            .dir("node_modules", [.repo("now-visible")]),
            .dir("opt-out", [.repo("hidden")])
        ])

        let opts = RepoDiscovery.Options(
            includeHidden: false,
            skipNames: ["opt-out"]
        )
        let repos = RepoDiscovery.scan(root: root, options: opts)
            .map(\.lastPathComponent).sorted()
        #expect(repos == ["now-visible"])
    }

    @Test("an empty / non-existent root yields no repos and does not crash")
    func emptyAndMissingRoots() throws {
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-discovery-missing-\(UUID().uuidString)")
        let repos = RepoDiscovery.scan(root: nonexistent)
        #expect(repos.isEmpty)

        let empty = try tempRoot("empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(RepoDiscovery.scan(root: empty).isEmpty)
    }
}
