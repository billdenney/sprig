// CommitMessageSuggestion.swift
//
// ADR 0074 — the deterministic, non-AI default for "what do I write
// here" (beginner-affordances item 2.5). Two sources, in priority
// order:
//
//   1. The repo's own `commit.template` (git config; ADR 0023
//      defer-to-git — teams that configured a template get exactly
//      what `git commit` in a terminal would show). First line →
//      subject seed, rest → body; comment lines (`#`) stripped.
//   2. A synthesized subject from the staged paths:
//        one file            → "Update <name>"
//        one directory       → "Update <dir> (<N> files)"
//        mixed               → "Update <N> files across <M> directories"
//      New-only stagings say "Add" instead of "Update" when every
//      staged path is untracked-new. Deliberately humble — a seed the
//      user edits, not prose pretending to know intent.
//
// The AI drafting path (ADR 0035) remains the opt-in upgrade;
// this gives the never-enable-AI user a working default
// (the maintainer's less-AI directive, 2026-06-09).

import Foundation
import GitCore

/// Builds the suggestion. Stateless; the runner carries the repo.
public enum CommitMessageSuggestion {
    /// Compose a suggested ``CommitMessage`` for the given staged
    /// partition. Returns nil when there is nothing to base a
    /// suggestion on (no template configured AND nothing staged) —
    /// the UI keeps its empty placeholder.
    ///
    /// - Parameters:
    ///   - stagedPaths: the composer's current staged list.
    ///   - newPaths: subset of `stagedPaths` that are newly added
    ///     (drives Add vs Update wording).
    ///   - runner: for the `git config commit.template` lookup.
    ///   - repoURL: resolves a relative template path.
    public static func suggest(
        stagedPaths: [String],
        newPaths: Set<String> = [],
        runner: Runner,
        repoURL: URL
    ) async -> CommitMessage? {
        if let fromTemplate = await templateMessage(runner: runner, repoURL: repoURL) {
            return fromTemplate
        }
        guard !stagedPaths.isEmpty else { return nil }
        return CommitMessage(
            subject: synthesizedSubject(stagedPaths: stagedPaths, newPaths: newPaths),
            body: ""
        )
    }

    // MARK: - commit.template

    /// Load + parse the repo's `commit.template`, if configured and
    /// readable. Best-effort: unreadable/missing template files fall
    /// through to synthesis (matching git, which warns but proceeds).
    static func templateMessage(runner: Runner, repoURL: URL) async -> CommitMessage? {
        guard let path = await templatePath(runner: runner) else { return nil }
        let url: URL = if (path as NSString).isAbsolutePath {
            URL(fileURLWithPath: path)
        } else {
            repoURL.appendingPathComponent(path)
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseTemplate(raw)
    }

    private static func templatePath(runner: Runner) async -> String? {
        guard let result = try? await runner.run(
            ["config", "--get", "commit.template"],
            throwOnNonZero: false
        ), result.exitCode == 0 else { return nil }
        var path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // git config supports "~/" expansion for this key; mirror it.
        if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    /// Split template text into subject (first non-comment line) +
    /// body (the rest), dropping `#` comment lines the way
    /// `git commit` strips them from the final message.
    static func parseTemplate(_ raw: String) -> CommitMessage? {
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
        guard let first = lines.first else { return nil }
        let subject = first.trimmingCharacters(in: .whitespaces)
        let body = lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty, body.isEmpty { return nil }
        return CommitMessage(subject: subject, body: body)
    }

    // MARK: - Path synthesis

    /// Deterministic subject from the staged paths. Pure — unit-
    /// testable without git.
    static func synthesizedSubject(
        stagedPaths: [String],
        newPaths: Set<String>
    ) -> String {
        let verb = !stagedPaths.isEmpty && Set(stagedPaths).subtracting(newPaths).isEmpty
            ? "Add"
            : "Update"
        if stagedPaths.count == 1, let only = stagedPaths.first {
            return "\(verb) \(fileName(of: only))"
        }
        let directories = Set(stagedPaths.map(directory(of:)))
        if directories.count == 1, let dir = directories.first {
            return "\(verb) \(dir) (\(stagedPaths.count) files)"
        }
        return "\(verb) \(stagedPaths.count) files across \(directories.count) directories"
    }

    private static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func directory(of path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return "." }
        return components.dropLast().joined(separator: "/")
    }
}
