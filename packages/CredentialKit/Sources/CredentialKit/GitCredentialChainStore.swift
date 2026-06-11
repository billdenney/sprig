// GitCredentialChainStore.swift
//
// ADR 0080 — credential storage that defers to git, like everything
// else in Sprig (ADR 0023): secrets ride the user's existing
// `git credential` helper chain (osxkeychain on macOS, Git
// Credential Manager on Windows, libsecret/cache/store on Linux —
// whatever their git already uses), so Sprig adds no keystore
// dependency and the user inspects/clears tokens with the git
// tooling they already know.
//
// Isolation invariant: entries live under the synthetic host
// `<service>.sprig.invalid` — `.invalid` is RFC 2606-reserved and
// can never name a real host, so Sprig's entries can neither shadow
// nor clobber the user's real git credentials (helpers match on
// host). Pinned by the isolation test.
//
// Fail-loudly invariant: `git credential approve` exits 0 even when
// NO helper is configured (the write silently goes nowhere), so
// ``store(secret:service:account:)`` verifies with a read-back and
// throws ``CredentialStoreError/noUsableBackend`` instead of letting
// the caller believe a secret was kept. One extra spawn, bought
// honesty.
//
// Portable (Tier-2 package, portable default implementation): the
// wire format is line-based key=value over stdin — no platform code.

import Foundation
import GitCore

/// `CredentialStore` over the user's `git credential` helper chain.
public struct GitCredentialChainStore: CredentialStore {
    private let runner: Runner

    /// - Parameter runner: carries the working directory (so a
    ///   repo-local `credential.helper` applies — tests use that)
    ///   and env scrubbing. GUI askpass hooks are stripped on top of
    ///   the runner's own `GIT_TERMINAL_PROMPT=0` so a fill with no
    ///   stored entry returns "nothing" instead of prompting.
    public init(runner: Runner) {
        var hardened = runner
        hardened.environmentOverrides.updateValue(nil, forKey: "GIT_ASKPASS")
        hardened.environmentOverrides.updateValue(nil, forKey: "SSH_ASKPASS")
        self.runner = hardened
    }

    public func store(secret: String, service: String, account: String) async throws {
        try Self.validate(secret: secret, service: service, account: account)
        _ = try await runner.run(
            ["credential", "approve"],
            stdin: Self.wire(service: service, account: account, password: secret)
        )
        // approve is a silent no-op on a helperless chain — verify.
        guard try await retrieve(service: service, account: account) == secret else {
            throw CredentialStoreError.noUsableBackend
        }
    }

    public func retrieve(service: String, account: String) async throws -> String? {
        try Self.validate(secret: nil, service: service, account: account)
        let result = try await runner.run(
            ["credential", "fill"],
            stdin: Self.wire(service: service, account: account, password: nil),
            throwOnNonZero: false
        )
        // Non-zero covers both "no helper configured" and "helper has
        // no entry" (git falls through to prompting, which the env
        // disables) — uniformly "nothing stored".
        guard result.exitCode == 0 else { return nil }
        let line = result.stdoutString.split(separator: "\n")
            .first { $0.hasPrefix("password=") }
        return line.map { String($0.dropFirst("password=".count)) }
    }

    public func remove(service: String, account: String) async throws {
        try Self.validate(secret: nil, service: service, account: account)
        _ = try await runner.run(
            ["credential", "reject"],
            stdin: Self.wire(service: service, account: account, password: nil)
        )
    }

    // MARK: - Wire format

    /// The synthetic host an entry lives under. `.invalid` is
    /// RFC 2606-reserved: never resolvable, never a host the user's
    /// real credentials could be keyed on.
    static func syntheticHost(service: String) -> String {
        "\(service).sprig.invalid"
    }

    private static func wire(service: String, account: String, password: String?) -> Data {
        var lines = [
            "protocol=https",
            "host=\(syntheticHost(service: service))",
            "username=\(account)"
        ]
        if let password {
            lines.append("password=\(password)")
        }
        return Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }

    /// The `git credential` wire format is newline-delimited
    /// key=value — a newline or NUL in any field would inject keys.
    /// Service doubles as a hostname label, so it is restricted to
    /// `[a-z0-9.-]`; accounts and secrets just need to be
    /// line-clean.
    private static func validate(
        secret: String?,
        service: String,
        account: String
    ) throws {
        let serviceCharset = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !service.isEmpty,
              service.unicodeScalars.allSatisfy(serviceCharset.contains)
        else {
            throw CredentialStoreError.invalidInput(
                detail: "service must be non-empty [a-z0-9.-]: '\(service)'"
            )
        }
        guard !account.isEmpty, lineClean(account) else {
            throw CredentialStoreError.invalidInput(detail: "account must be one clean line")
        }
        if let secret {
            guard !secret.isEmpty, lineClean(secret) else {
                throw CredentialStoreError.invalidInput(detail: "secret must be one clean line")
            }
        }
    }

    private static func lineClean(_ value: String) -> Bool {
        !value.contains("\n") && !value.contains("\r") && !value.contains("\0")
    }
}
