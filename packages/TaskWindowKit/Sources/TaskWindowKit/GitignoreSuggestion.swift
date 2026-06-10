// GitignoreSuggestion.swift
//
// ADR 0070 amendment — the ".gitignore suggestion" affordance
// (maintainer-ratified 2026-06-11): when untracked files match the
// curated junk patterns (likely secrets, tool temporaries —
// `GitCore.JunkFilePatterns`), Sprig SUGGESTS adding those patterns
// to the repo's root `.gitignore`. Suggest only, never force: the
// shells render a banner with the matched files; ``append(...)``
// runs solely on the user's click. Works for new and existing repos
// and existing `.gitignore` files (appends; never rewrites; skips
// lines already present).
//
// This pairs with the ADR 0075 backup deny-list: a file the backup
// engine silently skips is exactly a file the user should hear
// about once, with a one-click durable fix.

import Foundation
import GitCore

/// One suggested `.gitignore` line plus the evidence for it.
public struct SuggestedIgnore: Sendable, Equatable {
    /// The `.gitignore`-format line to add (e.g. `*.env`, `~$*`).
    public let pattern: String
    /// Why this rule fires — drives the banner copy register.
    public let category: JunkFilePattern.Category
    /// The untracked paths that matched (shown as evidence).
    public let matchedPaths: [String]

    public init(pattern: String, category: JunkFilePattern.Category, matchedPaths: [String]) {
        self.pattern = pattern
        self.category = category
        self.matchedPaths = matchedPaths
    }
}

/// Detection (pure) + the consent-gated append action.
public enum GitignoreSuggestion {
    /// Which junk rules match the given untracked paths. Pure — no
    /// filesystem or git access; callers pass the untracked list a
    /// porcelain refresh already produced. Rules whose pattern is
    /// already ignored never appear here because ignored files don't
    /// show up as untracked in the first place.
    public static func detect(
        untrackedPaths: [String],
        rules: [JunkFilePattern] = JunkFilePatterns.all
    ) -> [SuggestedIgnore] {
        var matches: [String: [String]] = [:]
        for path in untrackedPaths {
            guard let rule = JunkFilePatterns.rule(matching: path, in: rules) else { continue }
            matches[rule.gitignoreLine, default: []].append(path)
        }
        return rules.compactMap { rule in
            guard let paths = matches[rule.gitignoreLine] else { return nil }
            return SuggestedIgnore(
                pattern: rule.gitignoreLine,
                category: rule.category,
                matchedPaths: paths.sorted()
            )
        }
    }

    /// Append the accepted patterns to `<repoRoot>/.gitignore` —
    /// the user-consent action behind the banner's button. Creates
    /// the file when missing; appends a one-time `# Added by Sprig`
    /// section header; skips patterns already present as exact lines
    /// (modulo surrounding whitespace). Returns the lines actually
    /// written, so the caller can report "added 2, 1 already there".
    @discardableResult
    public static func append(patterns: [String], toRepoRoot repoRoot: URL) throws -> [String] {
        try IgnoreFileEditor.append(
            patterns: patterns,
            to: repoRoot.appendingPathComponent(".gitignore"),
            header: "# Added by Sprig (likely secrets / temporary files)"
        )
    }
}
