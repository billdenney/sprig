// CloneCommand.swift
//
// `sprigctl clone` — the CLI face of the Clone surface, closing
// ADR 0078's noted consequence ("a sprigctl clone --browse face
// needs a token source"): the token source is ADR 0080/0081.
//
//   sprigctl clone <url> [directory] [--depth N] [--no-submodules]
//   sprigctl clone --browse --provider github [directory]
//
// Plain mode drives the same `CloneDialogViewModel` the task
// windows bind (CLI/shell parity, like StatusCommand). Browse mode
// lists the signed-in account's repositories (ForgeRepoBrowser,
// token via the git credential chain), prints a numbered list, and
// reads the pick from stdin. The default target directory is the
// repository's name, like git's own default.

import ArgumentParser
import CredentialKit
import ForgeKit
import Foundation
import GitCore
import TaskWindowKit

struct CloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a repository by URL, or browse your forge repos and pick one."
    )

    @Argument(help: "Repository URL or path to clone (omit with --browse).")
    var url: String?

    @Argument(help: "Target directory (defaults to the repository's name).")
    var directory: String?

    @Flag(name: .long, help: "Pick from your repositories on a forge instead of pasting a URL.")
    var browse: Bool = false

    @Option(name: .long, help: "Forge to browse (github, gitlab, bitbucket, gitea); requires --browse.")
    var provider: ForgeProvider?

    @Option(name: .long, help: "Forge API base URL for self-hosted instances (browse mode).")
    var baseUrl: String?

    @Option(name: .long, help: "Shallow clone depth.")
    var depth: Int?

    @Flag(name: .long, help: "Skip --recurse-submodules.")
    var noSubmodules: Bool = false

    func run() async throws {
        let source: String
        switch (url, browse) {
        case (let .some(url), false):
            source = url
        case (nil, true):
            source = try await pickFromForge()
        case (.some, true):
            throw ValidationError("give a URL or --browse, not both")
        case (nil, false):
            throw ValidationError("give a repository URL, or --browse to pick from a forge")
        }

        let target = directory ?? Self.defaultDirectory(for: source)
        guard !target.isEmpty else {
            throw ValidationError("could not derive a directory name from '\(source)' — pass one explicitly")
        }
        try await clone(source: source, into: target)
    }

    // MARK: - Plain clone (CloneDialogViewModel-backed)

    private func clone(source: String, into target: String) async throws {
        let targetURL = URL(fileURLWithPath: target).standardized
        let parent = targetURL.deletingLastPathComponent()
        let vm = CloneDialogViewModel(
            request: CloneRequest(
                sourceURL: source,
                targetDirectory: targetURL.path,
                recurseSubmodules: !noSubmodules,
                depth: depth
            ),
            runner: Runner(defaultWorkingDirectory: parent)
        )
        await vm.clone()
        switch await vm.state {
        case let .success(cloned):
            var out = StdoutStream()
            print("Cloned into \(cloned.path)", to: &out)
        case let .failure(failure):
            var err = StderrStream()
            print("clone failed: \(failure.description)", to: &err)
            throw ExitCode(1)
        case .idle, .busy:
            throw ExitCode(1)
        }
    }

    /// Git's own default: the source's last path component, minus a
    /// trailing `.git`.
    static func defaultDirectory(for source: String) -> String {
        let trimmed = source.hasSuffix("/") ? String(source.dropLast()) : source
        var name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        // scp-style remotes: git@host:owner/name(.git)
        if let colonPart = name.split(separator: ":").last {
            name = String(colonPart)
        }
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        return name
    }

    // MARK: - Browse mode (ADR 0078 + 0080 + 0081 composed)

    private func pickFromForge() async throws -> String {
        guard let provider else {
            throw ValidationError("--browse needs --provider (github, gitlab, bitbucket, gitea)")
        }
        let store = GitCredentialChainStore(
            runner: Runner(defaultWorkingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ))
        )
        guard let token = try await store.retrieve(
            service: "forge.\(provider.rawValue)",
            account: "token"
        ) else {
            throw ValidationError(
                """
                not connected to \(provider.rawValue) — run `sprigctl forge login \
                --provider \(provider.rawValue) --client-id <id>` (or store a personal \
                access token with `sprigctl credential --set --service \
                forge.\(provider.rawValue) --account token`)
                """
            )
        }

        let repos: [ForgeRepo]
        do {
            repos = try await ForgeRepoBrowser().listRepos(
                provider: provider,
                token: token,
                baseURL: parsedBaseURL()
            )
        } catch ForgeError.unauthorized {
            throw ValidationError(
                "the stored \(provider.rawValue) token was rejected — sign in again with `sprigctl forge login`"
            )
        }
        guard !repos.isEmpty else {
            throw ValidationError("no repositories visible to this \(provider.rawValue) account")
        }

        var out = StdoutStream()
        for (index, repo) in repos.enumerated() {
            let privacy = repo.isPrivate ? " (private)" : ""
            let description = repo.description.map { " — \($0)" } ?? ""
            print("\(index + 1). \(repo.fullName)\(privacy)\(description)", to: &out)
        }
        print("Clone which repository? [1-\(repos.count)] ", to: &out)

        guard let line = readLine(strippingNewline: true),
              let pick = Int(line.trimmingCharacters(in: .whitespaces)),
              (1 ... repos.count).contains(pick)
        else {
            throw ValidationError("expected a number between 1 and \(repos.count)")
        }
        return repos[pick - 1].cloneURL
    }

    private func parsedBaseURL() throws -> URL? {
        guard let baseUrl else { return nil }
        guard let url = URL(string: baseUrl), url.scheme != nil else {
            throw ValidationError("--base-url is not a URL: \(baseUrl)")
        }
        return url
    }
}
