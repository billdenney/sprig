// CredentialCommand.swift
//
// `sprigctl credential` — the CLI face of ADR 0080's defer-to-git
// secret storage. Three mutually-exclusive verbs:
//
//   sprigctl credential --set    --service forge.github --account token [repo]
//   sprigctl credential --get    --service forge.github --account token [repo]
//   sprigctl credential --remove --service forge.github --account token [repo]
//
// `--set` reads the secret from STDIN (never argv — argv is visible
// to every process on the machine via `ps`). `--get` prints the
// secret to stdout for scripting; a missing secret is exit code 1
// with a stderr explanation, distinguishing "not stored" from
// storage errors.

import ArgumentParser
import CredentialKit
import Foundation
import GitCore

struct CredentialCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credential",
        abstract: "Store, read, or forget a secret via the user's git credential helper chain."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "Store a secret read from stdin.")
    var set: Bool = false

    @Flag(name: .long, help: "Print the stored secret to stdout.")
    var get: Bool = false

    @Flag(name: .long, help: "Forget the stored secret (idempotent).")
    var remove: Bool = false

    @Option(name: .long, help: "Namespace for the secret, e.g. forge.github ([a-z0-9.-]).")
    var service: String

    @Option(name: .long, help: "Account label within the service, e.g. token.")
    var account: String

    func run() async throws {
        let store = GitCredentialChainStore(runner: makeRunner())
        switch (set, get, remove) {
        case (true, false, false):
            try await runSet(store: store)
        case (false, true, false):
            try await runGet(store: store)
        case (false, false, true):
            try await store.remove(service: service, account: account)
        default:
            throw ValidationError("specify exactly one of --set, --get, or --remove")
        }
    }

    private func runSet(store: GitCredentialChainStore) async throws {
        let raw = try FileHandle.standardInput.readToEnd() ?? Data()
        guard var secret = String(data: raw, encoding: .utf8) else {
            throw ValidationError("stdin was not UTF-8")
        }
        // Trim the trailing newline `echo`/heredocs append; an
        // interior newline is still rejected by the store's
        // wire-format validation.
        while secret.hasSuffix("\n") || secret.hasSuffix("\r") {
            secret.removeLast()
        }
        guard !secret.isEmpty else {
            throw ValidationError("no secret on stdin (pipe it in: `echo TOKEN | sprigctl credential --set …`)")
        }
        try await store.store(secret: secret, service: service, account: account)
    }

    private func runGet(store: GitCredentialChainStore) async throws {
        guard let secret = try await store.retrieve(service: service, account: account) else {
            var err = StderrStream()
            print("no secret stored for \(service)/\(account)", to: &err)
            throw ExitCode(1)
        }
        var out = StdoutStream()
        print(secret, to: &out)
    }

    private func makeRunner() -> Runner {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        return Runner(defaultWorkingDirectory: repoURL)
    }
}
