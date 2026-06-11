// GlobalExcludes.swift
//
// §11.11 / ADR 0049 amendment — the "ask less" mechanic for OS
// noise: instead of every repository eventually asking "ignore
// .DS_Store here?", provision the user's GLOBAL excludes file once
// and the question never arises again (ignored files never show as
// untracked, so the per-repo suggestion banner stays quiet too).
//
// Consent model: provisioning is an EXPLICIT act (onboarding, or
// `sprigctl setup --global-ignore`) — never a background side
// effect. And it never touches git config: when `core.excludesFile`
// is set we append to the user's chosen file; when it's unset we
// write git's own documented default location
// (`$XDG_CONFIG_HOME/git/ignore`, falling back to
// `~/.config/git/ignore`), which git reads without any config key
// existing. CLAUDE.md's "never silently rewrite user git config"
// holds by construction.

import Foundation

/// Resolve + provision the user's global excludes file.
public enum GlobalExcludes {
    /// The Sprig section header (header-once contract, same
    /// mechanics as the per-repo `.gitignore` suggestion).
    public static let header = "# Added by Sprig (OS noise — applies to all your repositories)"

    /// The lines provisioning adds: `JunkFilePatterns.osNoise`.
    public static var patterns: [String] {
        JunkFilePatterns.osNoise.map(\.gitignoreLine)
    }

    /// Where the global excludes live. `core.excludesFile` wins (any
    /// scope, like git itself); unset means git's documented default
    /// `$XDG_CONFIG_HOME/git/ignore` → `~/.config/git/ignore`.
    /// `~` in a configured value expands against HOME.
    ///
    /// `environment` is injectable for tests; production callers use
    /// the process environment.
    public static func resolveExcludesFile(
        runner: Runner,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> URL {
        let configured = try await runner.run(
            ["config", "--get", "core.excludesFile"],
            throwOnNonZero: false
        )
        let value = configured.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.exitCode == 0, !value.isEmpty {
            return expandTilde(value, environment: environment)
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
                .appendingPathComponent("git").appendingPathComponent("ignore")
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config")
            .appendingPathComponent("git")
            .appendingPathComponent("ignore")
    }

    /// The consent action: append the missing OS-noise patterns to
    /// the resolved file (creating it and its directory when
    /// missing), under the one-time Sprig header. Already-present
    /// lines are skipped; existing content is never rewritten.
    /// Returns the resolved file plus the lines actually written —
    /// empty when everything was already covered.
    @discardableResult
    public static func provision(
        runner: Runner,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (file: URL, added: [String]) {
        let file = try await resolveExcludesFile(runner: runner, environment: environment)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let added = try IgnoreFileEditor.append(patterns: patterns, to: file, header: header)
        return (file, added)
    }

    private static func expandTilde(_ path: String, environment: [String: String]) -> URL {
        guard path.hasPrefix("~") else { return URL(fileURLWithPath: path) }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let suffix = String(path.dropFirst()).drop(while: { $0 == "/" })
        return suffix.isEmpty
            ? URL(fileURLWithPath: home)
            : URL(fileURLWithPath: home).appendingPathComponent(String(suffix))
    }
}

/// Append-only ignore-file editing: header-once, line-dedup, never
/// rewrites existing content. Shared by the per-repo `.gitignore`
/// suggestion (TaskWindowKit) and ``GlobalExcludes``.
public enum IgnoreFileEditor {
    /// Returns the lines actually written (deduped against existing
    /// exact lines, modulo surrounding whitespace).
    @discardableResult
    public static func append(
        patterns: [String],
        to url: URL,
        header: String
    ) throws -> [String] {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let existingLines = Set(
            existing.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        let additions = patterns.filter { !existingLines.contains($0) }
        guard !additions.isEmpty else { return [] }

        var content = existing
        if !content.isEmpty, !content.hasSuffix("\n") {
            content += "\n"
        }
        if !existingLines.contains(header) {
            content += header + "\n"
        }
        content += additions.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: url)
        return additions
    }
}
