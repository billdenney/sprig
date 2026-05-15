// PathResolver.swift
//
// The portable path-resolution protocol — master plan §2 / ADR 0048's
// abstraction for "where does Sprig keep its data on this OS?" Lives
// in PlatformKit (Tier 1) as a protocol; the default
// ``FoundationPathResolver`` impl uses Foundation's
// platform-aware URL APIs and works on macOS, Linux, and Windows
// without per-OS code.
//
// Consumers:
//   - `TaskWindowKit.PreferencesViewModel` (per ADR 0037-ish prefs
//     storage; currently takes an injected URL, but production
//     callers should ask the resolver instead of computing the path).
//   - `AIKit` prompt overrides (ADR 0037 — `~/Library/Application
//     Support/Sprig/prompts/` on macOS; the resolver computes the
//     equivalent on each OS).
//   - Future Recover task window, snapshot-ref TTL cache, diagnostic
//     bundle output, etc.
//
// The resolver is intentionally minimal — only paths Sprig has a
// concrete need for today. Adding a new well-known path is one
// protocol member + one default-impl method + one test.

import Foundation

/// Resolves Sprig's well-known per-user directories on the current
/// platform. Conformers may compute paths via Foundation's domain-
/// specific URL APIs, or any other mechanism — tests inject
/// alternative resolvers that point at temp dirs.
public protocol PathResolver: Sendable {
    /// The application-support root for Sprig — where the app's
    /// JSON prefs, user-overridable prompts, snapshot-index caches,
    /// and similar persistent state live. On macOS this is
    /// `~/Library/Application Support/<appName>`; on Linux it
    /// follows XDG (`~/.local/share/<appName>`); on Windows it's
    /// `%APPDATA%\<appName>`. The directory is created if missing.
    func appSupport() throws -> URL

    /// The cache root — non-essential data Sprig can recompute on
    /// demand if absent (e.g. cached `git for-each-ref` snapshots,
    /// thumbnail-style derivations). On macOS `~/Library/Caches/
    /// <appName>`; XDG-cache (`~/.cache/<appName>`) on Linux;
    /// `%LOCALAPPDATA%\<appName>\Cache` on Windows. Created if
    /// missing.
    func cache() throws -> URL
}

/// Default implementation backed by Foundation's
/// `FileManager.url(for:in:appropriateFor:create:)`. Cross-platform
/// because Foundation's `SearchPathDirectory` enum maps to the
/// platform-correct well-known directory on every supported OS.
///
/// **Customizable app name.** Defaults to `"Sprig"` so the
/// production shells get the expected directory. Tests typically
/// pass a UUID-suffixed name so concurrent test runs don't share
/// state.
public struct FoundationPathResolver: PathResolver {
    /// The application name suffixed to each well-known root. Defaults
    /// to `"Sprig"`. Customize for tests or for in-process forks /
    /// experimental builds that want isolated state.
    public let appName: String

    public init(appName: String = "Sprig") {
        self.appName = appName
    }

    public func appSupport() throws -> URL {
        try wellKnown(.applicationSupportDirectory)
    }

    public func cache() throws -> URL {
        try wellKnown(.cachesDirectory)
    }

    /// Resolve the OS's well-known root for `searchPath`, append
    /// ``appName``, and ensure the directory exists.
    private func wellKnown(_ searchPath: FileManager.SearchPathDirectory) throws -> URL {
        let root = try FileManager.default.url(
            for: searchPath,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = root.appendingPathComponent(appName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: appDir,
            withIntermediateDirectories: true
        )
        return appDir
    }
}
