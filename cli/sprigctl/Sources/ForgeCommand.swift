// ForgeCommand.swift
//
// `sprigctl forge` — connect a forge account (ADR 0081):
//
//   sprigctl forge login  --provider github --client-id <id> [--base-url U] [repo]
//   sprigctl forge logout --provider github [repo]
//   sprigctl forge status --provider github [repo]
//
// `login` runs the RFC 8628 device flow (show code → user approves
// in a browser → poll) and stores the token via the user's git
// credential helper chain (ADR 0080) under service
// `forge.<provider>` / account `token` — the same key
// `sprigctl credential` and the clone-browse face read. `status`
// exits 0/1 for scripting; `logout` is idempotent.

import ArgumentParser
import CredentialKit
import ForgeKit
import Foundation
import GitCore

extension ForgeProvider: ExpressibleByArgument {}

struct ForgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forge",
        abstract: "Connect a forge account (GitHub, GitLab) for repo browsing.",
        subcommands: [
            ForgeLoginCommand.self,
            ForgeLogoutCommand.self,
            ForgeStatusCommand.self
        ]
    )
}

/// Shared bits: the (service, account) convention and the store.
enum ForgeAccountKey {
    static let account = "token"

    static func service(_ provider: ForgeProvider) -> String {
        "forge.\(provider.rawValue)"
    }

    static func store(path: String?) -> GitCredentialChainStore {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        return GitCredentialChainStore(runner: Runner(defaultWorkingDirectory: repoURL))
    }
}

struct ForgeLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign in via the forge's device flow and store the token."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Option(name: .long, help: "Forge to sign in to (github, gitlab).")
    var provider: ForgeProvider

    @Option(name: .long, help: "OAuth app client id (registration is per-distribution).")
    var clientId: String

    @Option(name: .long, help: "Forge WEB base URL for self-hosted instances.")
    var baseUrl: String?

    func run() async throws {
        let base = try parsedBaseURL()
        let flow = ForgeDeviceFlow()
        let authorization: DeviceAuthorization
        do {
            authorization = try await flow.begin(
                provider: provider,
                clientID: clientId,
                baseURL: base
            )
        } catch let DeviceFlowError.unsupportedProvider(unsupported) {
            throw ValidationError(
                """
                \(unsupported.rawValue) has no device sign-in — create a personal access \
                token on the forge and store it with: sprigctl credential --set \
                --service \(ForgeAccountKey.service(unsupported)) \
                --account \(ForgeAccountKey.account)
                """
            )
        }

        var out = StdoutStream()
        print("Visit \(authorization.verificationURI) and enter code: \(authorization.userCode)", to: &out)
        print("Waiting for approval…", to: &out)

        let token = try await flow.awaitToken(
            provider: provider,
            clientID: clientId,
            authorization: authorization,
            baseURL: base
        )
        do {
            try await ForgeAccountKey.store(path: path).store(
                secret: token,
                service: ForgeAccountKey.service(provider),
                account: ForgeAccountKey.account
            )
        } catch CredentialStoreError.noUsableBackend {
            throw ValidationError(
                """
                signed in, but your git has no credential helper configured — the token \
                has nowhere safe to live. Configure one (osxkeychain on macOS, manager \
                on Windows, libsecret/store on Linux) and retry.
                """
            )
        }
        print("Connected \(provider.rawValue). Token stored via your git credential helper.", to: &out)
    }

    private func parsedBaseURL() throws -> URL? {
        guard let baseUrl else { return nil }
        guard let url = URL(string: baseUrl), url.scheme != nil else {
            throw ValidationError("--base-url is not a URL: \(baseUrl)")
        }
        return url
    }
}

struct ForgeLogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Forget the stored token for a forge (idempotent)."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Option(name: .long, help: "Forge to disconnect (github, gitlab, bitbucket, gitea).")
    var provider: ForgeProvider

    func run() async throws {
        try await ForgeAccountKey.store(path: path).remove(
            service: ForgeAccountKey.service(provider),
            account: ForgeAccountKey.account
        )
        var out = StdoutStream()
        print("Disconnected \(provider.rawValue).", to: &out)
    }
}

struct ForgeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether a token is stored for a forge (exit 0 yes, 1 no)."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Option(name: .long, help: "Forge to check (github, gitlab, bitbucket, gitea).")
    var provider: ForgeProvider

    func run() async throws {
        let stored = try await ForgeAccountKey.store(path: path).retrieve(
            service: ForgeAccountKey.service(provider),
            account: ForgeAccountKey.account
        )
        var out = StdoutStream()
        if stored != nil {
            print("\(provider.rawValue): connected (token stored).", to: &out)
        } else {
            print("\(provider.rawValue): not connected.", to: &out)
            throw ExitCode(1)
        }
    }
}
