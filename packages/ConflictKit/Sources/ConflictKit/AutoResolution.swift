// AutoResolution.swift
//
// Heuristics that suggest a `ConflictResolution` for a region without
// requiring a user pick. Useful in two places:
//
//   - The merge UI's first pass — silently resolve regions where the
//     two sides are equivalent, surfacing only the genuinely
//     conflicting ones to the user.
//   - The headless `sprigctl recover` / future `sprigctl mergetool`
//     path, where a CI / scripted user wants "do what's safe; bail on
//     anything that needs a human."
//
// Strategies are opt-in (via a `Set`) so each call site can pick the
// safety level it wants. The default-off posture matters because some
// strategies (like `.whitespaceOnly`) are unsafe in languages where
// whitespace is significant.

import Foundation

/// One auto-resolution strategy. Multiple may be enabled at once;
/// strategies are tried in source order, and the first that matches
/// returns a resolution.
public enum AutoResolutionStrategy: Sendable, Hashable, CaseIterable {
    /// Both sides have byte-for-byte identical content (`ours ==
    /// theirs`). Always safe — the conflict marker exists for a
    /// metadata reason (e.g. a binary file the merger couldn't
    /// compare), not a real divergence.
    case identical

    /// Both sides agree once leading and trailing whitespace is
    /// stripped from each line. The merge tool produced a marker only
    /// because of inconsistent indentation or trailing whitespace.
    ///
    /// **Caveat:** unsafe in languages where whitespace is
    /// significant (Python, YAML, Makefile, off-side-rule grammars).
    /// Callers that don't know the file's language should leave this
    /// off; the merge UI can offer it as a per-region override.
    case whitespaceOnly
}

public extension ConflictRegion {
    /// If this region can be auto-resolved under any of the supplied
    /// `strategies`, return the resulting ``ConflictResolution``.
    /// Returns nil if no strategy matches — the caller should surface
    /// the region to the user.
    ///
    /// When a match is found, the returned resolution is always
    /// `.ours` (both sides are equivalent under the matching
    /// strategy, so we pick the local side by convention).
    func autoResolution(strategies: Set<AutoResolutionStrategy>) -> ConflictResolution? {
        if strategies.contains(.identical), ours == theirs {
            return .ours
        }
        if strategies.contains(.whitespaceOnly) {
            let strippedOurs = ours.map { $0.trimmingCharacters(in: .whitespaces) }
            let strippedTheirs = theirs.map { $0.trimmingCharacters(in: .whitespaces) }
            if strippedOurs == strippedTheirs {
                return .ours
            }
        }
        return nil
    }
}

public extension ConflictedFile {
    /// Compute one ``ConflictResolution`` per region by running each
    /// region through ``ConflictRegion/autoResolution(strategies:)``.
    /// Regions that don't auto-resolve get
    /// ``ConflictResolution/unresolved``, leaving their marker block
    /// in place so a follow-up user pass can address them.
    ///
    /// The returned array always satisfies the count contract of
    /// ``applying(_:)`` (one element per region) so callers can
    /// chain `file.applying(file.autoResolutions(strategies: ...))`
    /// directly.
    func autoResolutions(strategies: Set<AutoResolutionStrategy>) -> [ConflictResolution] {
        regions.map { $0.autoResolution(strategies: strategies) ?? .unresolved }
    }

    /// True when every region auto-resolves under `strategies` — i.e.
    /// `applying(autoResolutions(...))` would produce a fully clean
    /// file.
    func isFullyAutoResolvable(strategies: Set<AutoResolutionStrategy>) -> Bool {
        regions.allSatisfy { $0.autoResolution(strategies: strategies) != nil }
    }
}
