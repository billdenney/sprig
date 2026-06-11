// GitCredentialChainStoreTests.swift
//
// ADR 0080 against real git (never mocked) with the real
// `git-credential-store` helper writing a temp file. The
// load-bearing claims:
//
//   - the (service, account) → secret round-trip works through the
//     actual helper chain, and the storage key is the synthetic
//     `<service>.sprig.invalid` host;
//   - Sprig's entries can neither shadow nor clobber the user's
//     real git credentials (the isolation pin);
//   - a helperless chain makes store() FAIL LOUDLY — `git
//     credential approve` exits 0 while storing nothing, and a
//     caller must never believe a secret was kept;
//   - wire-format injection (newlines in any field) is rejected
//     before anything spawns.
//
// Every fixture RESETS the helper chain (`credential.helper=""`)
// before adding its own helper: CI hosts and the Windows VM have
// system-wide helpers (Git Credential Manager, osxkeychain) that
// would otherwise intercept fills and make results machine-dependent.

@testable import CredentialKit
import Foundation
import GitCore
import Testing

@Suite("GitCredentialChainStore — git credential chain (real git)", .serialized)
struct GitCredentialChainStoreTests {
    /// A repo whose LOCAL config pins the helper chain to exactly
    /// one `store --file=<repo>/creds.txt` helper (the "" entry
    /// resets any system/global helpers first).
    private func makeRepo(_ label: String, withStoreHelper: Bool = true) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-credchain-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "credential.helper", ""])
        if withStoreHelper {
            _ = try await runner.run([
                "config", "--add", "credential.helper",
                "store --file=\(credsFile(dir).path.replacingOccurrences(of: "\\", with: "/"))"
            ])
        }
        return (dir, runner)
    }

    private func credsFile(_ dir: URL) -> URL {
        dir.appendingPathComponent("creds.txt")
    }

    private func credsContent(_ dir: URL) throws -> String {
        try String(contentsOf: credsFile(dir), encoding: .utf8)
    }

    @Test("store → retrieve round-trips; the storage key is the synthetic .sprig.invalid host")
    func roundTripAndStorageShape() async throws {
        let (dir, runner) = try await makeRepo("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GitCredentialChainStore(runner: runner)

        try await store.store(secret: "s3cr3t", service: "forge.github", account: "token")

        #expect(try await store.retrieve(service: "forge.github", account: "token") == "s3cr3t")
        #expect(
            try credsContent(dir)
                .contains("https://token:s3cr3t@forge.github.sprig.invalid")
        )
    }

    @Test("retrieve with nothing stored is nil, not an error")
    func retrieveMissingIsNil() async throws {
        let (dir, runner) = try await makeRepo("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GitCredentialChainStore(runner: runner)

        #expect(try await store.retrieve(service: "forge.github", account: "token") == nil)
    }

    @Test("a helperless chain makes store() throw noUsableBackend, never a silent no-op")
    func helperlessChainFailsLoudly() async throws {
        let (dir, runner) = try await makeRepo("nohelper", withStoreHelper: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GitCredentialChainStore(runner: runner)

        await #expect(throws: CredentialStoreError.noUsableBackend) {
            try await store.store(secret: "s", service: "forge.github", account: "token")
        }
        #expect(try await store.retrieve(service: "forge.github", account: "token") == nil)
    }

    @Test("remove forgets the secret and is idempotent")
    func removeIsIdempotent() async throws {
        let (dir, runner) = try await makeRepo("remove")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GitCredentialChainStore(runner: runner)
        try await store.store(secret: "s3cr3t", service: "forge.github", account: "token")

        try await store.remove(service: "forge.github", account: "token")

        #expect(try await store.retrieve(service: "forge.github", account: "token") == nil)
        // Idempotent: rejecting an absent entry is not an error.
        try await store.remove(service: "forge.github", account: "token")
    }

    @Test("Sprig entries neither shadow nor clobber the user's real git credentials")
    func isolationFromRealCredentials() async throws {
        let (dir, runner) = try await makeRepo("isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The user's pre-existing real credential for github.com.
        let real = "https://bill:realpass@github.com\n"
        try Data(real.utf8).write(to: credsFile(dir))
        let store = GitCredentialChainStore(runner: runner)

        try await store.store(secret: "sprig-tok", service: "forge.github", account: "token")

        // Sprig reads back its own secret, not the user's…
        #expect(try await store.retrieve(service: "forge.github", account: "token") == "sprig-tok")
        // …the user's line is still in the store, untouched…
        #expect(try credsContent(dir).contains("https://bill:realpass@github.com"))
        // …and a plain git fill for the real host still resolves the
        // user's credential, not Sprig's.
        let fill = try await runner.run(
            ["credential", "fill"],
            stdin: Data("protocol=https\nhost=github.com\nusername=bill\n\n".utf8)
        )
        #expect(fill.stdoutString.contains("password=realpass"))
        #expect(!fill.stdoutString.contains("sprig-tok"))
    }

    @Test("newlines in any field are rejected before anything spawns")
    func injectionRejected() async throws {
        let (dir, runner) = try await makeRepo("inject")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GitCredentialChainStore(runner: runner)

        await #expect(throws: CredentialStoreError.self) {
            try await store.store(
                secret: "x\nhost=evil.example",
                service: "forge.github",
                account: "token"
            )
        }
        await #expect(throws: CredentialStoreError.self) {
            try await store.store(secret: "x", service: "Forge_GitHub", account: "token")
        }
        await #expect(throws: CredentialStoreError.self) {
            _ = try await store.retrieve(service: "forge.github", account: "a\nb")
        }
        // Nothing leaked into storage from the rejected calls.
        #expect(!FileManager.default.fileExists(atPath: credsFile(dir).path))
    }

    @Test("secrets with URL-hostile characters round-trip exactly")
    func gnarlySecretRoundTrips() async throws {
        let (dir, runner) = try await makeRepo("gnarly")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GitCredentialChainStore(runner: runner)
        let gnarly = "p@ss w0rd=+&#%25:end"

        try await store.store(secret: gnarly, service: "forge.gitlab", account: "token")

        #expect(try await store.retrieve(service: "forge.gitlab", account: "token") == gnarly)
    }
}
