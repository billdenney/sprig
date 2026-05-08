// SubmoduleEntry — typed model for a single line of `git submodule status`.
//
// Tier 1 portable. Pure Foundation; no platform APIs.
//
// One value per submodule of a super-repo. Built by
// `SubmoduleStatusParser.parse(_:)` from the raw `git submodule status`
// output.

import Foundation

/// One entry in the output of `git submodule status [--recursive]
/// [--cached]`.
///
/// Each line of `git submodule status` describes one submodule. The
/// leading character names the submodule's state relative to the
/// super-repo's recorded pointer; the SHA, path, and optional
/// ref-description follow.
public struct SubmoduleEntry: Sendable, Equatable {
    /// State of the submodule relative to the super-repo's recorded
    /// pointer, as encoded by git in the line's leading character.
    ///
    /// Per `git-submodule(1)`, the prefix is one of `' '` / `'+'` /
    /// `'-'` / `'U'`. Anything else is rejected by the parser as
    /// `SubmoduleStatusParser.ParseError.unknownStateChar`.
    public enum State: Sendable, Equatable {
        /// `' '` — checkout SHA matches the super-repo's recorded SHA.
        case clean
        /// `'+'` — checkout SHA differs from the recorded SHA.
        case outOfDate
        /// `'-'` — submodule is registered in `.gitmodules` but has not
        /// been initialized (`git submodule init` / `git submodule
        /// update --init`). The `recordedSHA` is still meaningful: it's
        /// the super-repo's pointer, present in the tree from the moment
        /// the submodule was added.
        case notInitialized
        /// `'U'` — submodule has merge conflicts. ADR 0031 only requires
        /// three badge states (clean / out-of-date / init-needed); the
        /// future `SubmoduleManager` task window collapses this to
        /// `outOfDate` at the badge layer but consumes it directly when
        /// rendering its conflict column.
        case mergeConflict
    }

    /// State derived from the line's leading character.
    public var state: State

    /// The SHA the super-repo records for this submodule. Always
    /// present and meaningful — even for `notInitialized` entries,
    /// this is the pointer git recorded when the submodule was added,
    /// so it's the SHA an `init + update` would check out.
    ///
    /// Length is 40 hex characters for SHA-1 repos and 64 hex
    /// characters for SHA-256 repos (per `extensions.objectFormat`).
    /// Other lengths are rejected by the parser as
    /// `SubmoduleStatusParser.ParseError.shaUnexpectedShape`.
    public var recordedSHA: String

    /// The submodule's path, relative to the super-repo's worktree.
    ///
    /// Git emits forward-slash separators on every platform — Windows
    /// included — for ref/path-style fields like this. Callers who
    /// need a `URL` should compose it via `worktree
    /// .appendingPathComponent(path)` rather than treating the string
    /// as platform-native.
    public var path: String

    /// Optional `(refname)` suffix git appends when the submodule has
    /// a current ref describable by `git describe`. Nil when the
    /// submodule is on a detached HEAD that isn't `git describe`-able,
    /// when status was queried with `--cached` (the recorded SHA has
    /// no ref to describe), or when the submodule isn't initialized.
    ///
    /// Stored without the surrounding parentheses.
    public var refDescription: String?

    public init(
        state: State,
        recordedSHA: String,
        path: String,
        refDescription: String? = nil
    ) {
        self.state = state
        self.recordedSHA = recordedSHA
        self.path = path
        self.refDescription = refDescription
    }
}
