// JunkFilePatterns.swift
//
// The shared definition of "files Sprig should neither back up nor
// let silently pile up": likely secrets and tool/temporary droppings.
// One source of truth with two projections, used by two features:
//
//   * `SafetyKit.WorktreeBackup` excludes these from auto-backup
//     commits (ADR 0075 amendment) via the `pathspec` projection —
//     an unignored `.env` must not get persisted into git objects
//     every 30 minutes.
//   * The `.gitignore` suggestion affordance (ADR 0070 amendment)
//     uses the `gitignoreLine` projection plus `matches(basename:)`
//     to say "these untracked files look like they belong in
//     .gitignore — add them?" (suggest only, never automatic).
//
// Matching is by BASENAME, the way a path-less .gitignore line works.
// The pattern grammar is deliberately tiny — exact, `*.suffix`,
// `prefix*`, and `*infix*` — because these are curated constants,
// not user input. (User-extendable lists come later via Preferences;
// they'll reuse this matcher.)

import Foundation

/// One junk-file rule with its two projections.
public struct JunkFilePattern: Sendable, Equatable, Hashable {
    /// What kind of junk this guards against — drives copy and lets
    /// callers subset (e.g. a future "back up temp files anyway"
    /// toggle would filter on category).
    public enum Category: Sendable, Equatable, Hashable {
        /// Likely credential material (.env, private keys, …).
        case secret
        /// Tool/editor droppings (Office lock files, swap files, …).
        case temporary
    }

    /// The `.gitignore`-format line (basename pattern, no slash).
    public let gitignoreLine: String
    public let category: Category

    public init(gitignoreLine: String, category: Category) {
        self.gitignoreLine = gitignoreLine
        self.category = category
    }

    /// The `git add` pathspec projection: anchored to any directory
    /// depth with glob magic (`**/<pattern>`), for use as
    /// `:(exclude,glob)` pathspecs.
    public var pathspecGlob: String {
        "**/\(gitignoreLine)"
    }

    /// Does `basename` match this pattern? Supports the four shapes
    /// the curated list uses: exact, `*.suffix` / `*suffix`,
    /// `prefix*`, and `*infix*`. Case-insensitive — Windows and
    /// macOS default filesystems are, and `.ENV` should not dodge a
    /// secrets rule on Linux either.
    public func matches(basename: String) -> Bool {
        let name = basename.lowercased()
        let pattern = gitignoreLine.lowercased()
        let starsPrefix = pattern.hasPrefix("*")
        let starsSuffix = pattern.hasSuffix("*")
        let core = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        switch (starsPrefix, starsSuffix) {
        case (false, false): return name == pattern
        case (true, false): return name.hasSuffix(core)
        case (false, true): return name.hasPrefix(core)
        case (true, true): return name.contains(core)
        }
    }
}

/// The curated default rules (maintainer-ratified 2026-06-11:
/// standard secret set + typical temporary files).
public enum JunkFilePatterns {
    /// Likely credential material. NOTE the deliberate trade-off on
    /// the name-based rules (`*credentials*`, `*secret*`): they can
    /// match legitimate work files (`credentials_view.swift`), which
    /// are then silently NOT backed up — accepted because a leaked
    /// secret is worse than a narrower insurance net, and the
    /// .gitignore suggestion surfaces the skip to the user.
    public static let secrets: [JunkFilePattern] = [
        .init(gitignoreLine: "*.env", category: .secret),
        .init(gitignoreLine: ".env.*", category: .secret),
        .init(gitignoreLine: "*.pem", category: .secret),
        .init(gitignoreLine: "*.key", category: .secret),
        .init(gitignoreLine: "*.p12", category: .secret),
        .init(gitignoreLine: "*.pfx", category: .secret),
        .init(gitignoreLine: "id_rsa*", category: .secret),
        .init(gitignoreLine: "id_ed25519*", category: .secret),
        .init(gitignoreLine: "id_ecdsa*", category: .secret),
        .init(gitignoreLine: "*credentials*", category: .secret),
        .init(gitignoreLine: "*secret*", category: .secret)
    ]

    /// Tool/editor temporaries (Office `~$` lock files, generic
    /// temp/backup suffixes, vim swap, OS droppings).
    public static let temporaries: [JunkFilePattern] = [
        .init(gitignoreLine: "~$*", category: .temporary),
        .init(gitignoreLine: "*.tmp", category: .temporary),
        .init(gitignoreLine: "*.temp", category: .temporary),
        .init(gitignoreLine: "*.swp", category: .temporary),
        .init(gitignoreLine: "*.swo", category: .temporary),
        .init(gitignoreLine: "*~", category: .temporary),
        .init(gitignoreLine: ".DS_Store", category: .temporary),
        .init(gitignoreLine: "Thumbs.db", category: .temporary)
    ]

    /// Operating-system droppings (Finder/Explorer metadata) — the
    /// `GlobalExcludes` set (§11.11 "ask less": ignored once,
    /// globally, instead of per-repo questions forever). Narrower
    /// than ``temporaries`` on purpose: editor/Office temp files in
    /// a GLOBAL ignore would be too opinionated; OS metadata is
    /// junk in every repository by definition.
    public static let osNoise: [JunkFilePattern] = [
        .init(gitignoreLine: ".DS_Store", category: .temporary),
        .init(gitignoreLine: ".AppleDouble", category: .temporary),
        .init(gitignoreLine: "._*", category: .temporary),
        .init(gitignoreLine: ".Spotlight-V100", category: .temporary),
        .init(gitignoreLine: ".Trashes", category: .temporary),
        .init(gitignoreLine: "Thumbs.db", category: .temporary),
        .init(gitignoreLine: "ehthumbs.db", category: .temporary),
        .init(gitignoreLine: "Desktop.ini", category: .temporary)
    ]

    /// Everything, in suggestion-display order (secrets first).
    public static let all: [JunkFilePattern] = secrets + temporaries

    /// The `:(exclude,glob)`-ready pathspecs for backup staging.
    public static let backupExcludePathspecs: [String] = all.map(\.pathspecGlob)

    /// First matching rule for a path's basename, or nil.
    public static func rule(matching path: String, in rules: [JunkFilePattern] = all) -> JunkFilePattern? {
        let basename = path.split(separator: "/").last.map(String.init) ?? path
        return rules.first { $0.matches(basename: basename) }
    }
}
