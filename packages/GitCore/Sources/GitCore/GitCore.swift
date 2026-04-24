// GitCore — portable (Tier 1) package. No UI, no platform APIs.
// Must compile on macOS, Linux, and Windows Swift 6.3+.
// See CLAUDE.md and ADR 0048 for cross-platform discipline.
//
// Umbrella namespace. Concrete functionality lives in sibling files:
//   Runner.swift       — the git invoker
//   GitError.swift     — error types
//   GitExitCode.swift  — known exit code semantics
//   GitVersion.swift   — parsed version info

import Foundation

public enum GitCore {
    /// Semantic version of this module. Bumped when the public API changes.
    public static let moduleVersion = "0.1.0"
}
