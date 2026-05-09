// EnvironmentReport.swift
//
// Tier 1 portable. Pure Foundation. The runtime envelope DiagKit
// hands to support / issue templates / crash reports — every piece
// of "what was the user's environment when they ran into trouble"
// rolled into one Codable struct.
//
// Wire-stable. The JSON shape this encodes to is what Sprig support
// flows will read out of issue attachments years from now, so the
// shape is stable: existing fields don't change names or types,
// new fields are additive and optional.

import Foundation
import GitCore

/// Snapshot of the user's environment relevant to running Sprig:
/// engine version, OS info, the resolved git + git-lfs tooling.
///
/// Built by ``EnvironmentCollector/collect(runner:engineVersion:clock:)``;
/// callers (CLI, app shell, agent) supply the engine-version string
/// they're announcing themselves as.
public struct EnvironmentReport: Sendable, Equatable, Encodable {
    /// Sprig itself.
    public struct Engine: Sendable, Equatable, Encodable {
        /// Caller-supplied version (e.g., `sprigctl`'s `--version`
        /// string, or the macOS app's `CFBundleShortVersionString`).
        /// DiagKit doesn't try to discover this — it doesn't know
        /// which embedder it's living inside.
        public let version: String

        public init(version: String) {
            self.version = version
        }
    }

    /// Operating system the engine is running on.
    public struct OperatingSystem: Sendable, Equatable, Encodable {
        /// Coarse OS name: `"macOS"`, `"Linux"`, `"Windows"`, or
        /// `"Other"` for anything Foundation hasn't been built
        /// against. Branched on `#if os(...)` — falls under the
        /// "trivial cross-platform constants" exception in
        /// CLAUDE.md hard rule 2.
        public let name: String

        /// `ProcessInfo.processInfo.operatingSystemVersionString` —
        /// human-readable OS version. Shape varies per OS:
        /// `"Version 14.5 (Build 23F79)"` on macOS,
        /// `"Linux version 6.5.0-..."` on Linux, etc.
        public let versionString: String

        /// CPU architecture: `"arm64"`, `"x86_64"`, etc. Branched
        /// on `#if arch(...)` — same "trivial constants" exception.
        public let architecture: String

        public init(name: String, versionString: String, architecture: String) {
            self.name = name
            self.versionString = versionString
            self.architecture = architecture
        }
    }

    /// Parsed git semantic version (major.minor.patch + vendor
    /// suffix). Wire-encoded as a small object rather than a raw
    /// `GitVersion` so DiagKit's JSON contract doesn't depend on
    /// GitCore growing a `Codable` conformance. Sibling-level
    /// (rather than nested under `GitTooling`) to satisfy
    /// SwiftLint's max-1-level nesting rule.
    public struct GitSemver: Sendable, Equatable, Encodable {
        public let major: Int
        public let minor: Int
        public let patch: Int
        public let suffix: String

        public init(major: Int, minor: Int, patch: Int, suffix: String) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.suffix = suffix
        }

        public init(_ version: GitVersion) {
            self.init(
                major: version.major,
                minor: version.minor,
                patch: version.patch,
                suffix: version.suffix
            )
        }
    }

    /// `git` and `git-lfs` tooling resolved from the user's PATH.
    public struct GitTooling: Sendable, Equatable, Encodable {
        /// Raw `git --version` stdout, trimmed (e.g.
        /// `"git version 2.39.5 (Apple Git-154)"`). Nil iff git
        /// itself couldn't be invoked (binary missing, exec
        /// failure). DiagKit treats this as "the user has no
        /// usable git" rather than throwing — a missing-git
        /// report is still useful to support.
        public let gitVersionRaw: String?

        /// Parsed git version when ``gitVersionRaw`` matched
        /// `git version <X.Y.Z> [<vendor>]`. Nil for malformed or
        /// missing raw output.
        public let gitVersion: GitSemver?

        /// Raw `git lfs version` stdout, trimmed (e.g.
        /// `"git-lfs/3.4.0 (GitHub; ...)"`). Nil iff git-lfs
        /// isn't installed or `git lfs version` returned a
        /// non-zero exit. Distinct from "git itself isn't
        /// usable" — see ``gitVersionRaw``.
        public let gitLFSVersionRaw: String?

        public init(
            gitVersionRaw: String?,
            gitVersion: GitSemver?,
            gitLFSVersionRaw: String?
        ) {
            self.gitVersionRaw = gitVersionRaw
            self.gitVersion = gitVersion
            self.gitLFSVersionRaw = gitLFSVersionRaw
        }
    }

    public var engine: Engine
    public var os: OperatingSystem
    public var git: GitTooling

    /// Wall-clock instant the report was collected. Useful for
    /// "is this a fresh diagnostic?" checks when reports get
    /// pasted into issue templates.
    public var generatedAt: Date

    public init(
        engine: Engine,
        os: OperatingSystem,
        git: GitTooling,
        generatedAt: Date
    ) {
        self.engine = engine
        self.os = os
        self.git = git
        self.generatedAt = generatedAt
    }
}
