// TagOps.swift
//
// ADR 0087 — annotated-tag creation, the local-git half of "Create
// Release…": before publishing a forge Release, the user often needs a
// new annotated tag at a chosen commit. `git tag -a` creates a real tag
// object (message + tagger), the kind a release points at.
//
// Fail-closed on a pre-existing tag: a tag is a published-ish marker,
// and silently clobbering one (git refuses anyway without `-f`, which we
// never pass) is never wanted — surface a typed refusal instead.
//
// Tier 1, portable. All git access via ``Runner``.

import Foundation

/// Outcome of ``TagOps/createAnnotatedTag(name:message:at:)``.
public enum TagCreateOutcome: Sendable, Equatable {
    /// The annotated tag was created.
    case created(name: String)
    /// A tag with that name already exists — not overwritten.
    case refusedAlreadyExists(name: String)
}

/// Tag reads + annotated-tag creation.
public struct TagOps: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    /// Create an annotated tag `name` (message `message`) at `commit`
    /// (default `HEAD`). Refuses, rather than clobbers, when the tag
    /// already exists.
    public func createAnnotatedTag(
        name: String,
        message: String,
        at commit: String = "HEAD"
    ) async throws -> TagCreateOutcome {
        if try await exists(name) { return .refusedAlreadyExists(name: name) }
        let result = try await runner.run(
            ["tag", "-a", name, "-m", message, commit],
            throwOnNonZero: false
        )
        if result.exitCode == 0 { return .created(name: name) }
        // Lost a race to another writer, or git rejected the name; the
        // "already exists" stderr is the one we report rather than throw.
        if result.stderrString.contains("already exists") {
            return .refusedAlreadyExists(name: name)
        }
        throw GitError.nonZeroExit(
            command: ["tag", "-a", name, "-m", message, commit],
            exitCode: result.exitCode,
            stderr: result.stderrString,
            stdout: result.stdoutString
        )
    }

    /// Whether a tag with this name exists.
    public func exists(_ name: String) async throws -> Bool {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/tags/\(name)"],
            throwOnNonZero: false
        )
        return result.exitCode == 0
    }

    /// All tag names (lexical order, git's default).
    public func list() async throws -> [String] {
        let output = try await runner.run(["tag", "--list"]).stdoutString
        var tags: [String] = []
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { tags.append(trimmed) }
        }
        return tags
    }
}
