// CredentialStore.swift
//
// ADR 0080 — the portable secret-storage seam. Consumers (forge
// token onboarding, future in-shell credential prompts) speak this
// protocol; the default implementation defers to git's credential
// helper chain (``GitCredentialChainStore``), and native keystore
// adapters (Keychain / Credential Manager / Secret Service) remain
// the upgrade path behind the same protocol if helper-chain
// coverage proves insufficient.

import Foundation

/// Stores one secret per (service, account) pair.
///
/// Semantics every implementation must honor:
///   - ``store(secret:service:account:)`` replaces any prior value
///     and FAILS LOUDLY when nothing durable backs the write — a
///     caller must never believe a secret was kept when it wasn't.
///   - ``retrieve(service:account:)`` returns nil for "nothing
///     stored" (including "no backend available") — the caller's
///     reconnect-your-account signal.
///   - ``remove(service:account:)`` is idempotent.
public protocol CredentialStore: Sendable {
    func store(secret: String, service: String, account: String) async throws
    func retrieve(service: String, account: String) async throws -> String?
    func remove(service: String, account: String) async throws
}

/// Typed failures from ``CredentialStore`` implementations.
public enum CredentialStoreError: Error, Equatable, Sendable {
    /// An input would break the storage wire format (newlines/NULs
    /// in any field, or a service outside `[a-z0-9.-]`). Detected
    /// before anything is spawned.
    case invalidInput(detail: String)
    /// The write completed without error but a verification read
    /// could not get the secret back — nothing durable is storing
    /// credentials (e.g. no git credential helper is configured).
    case noUsableBackend
}
