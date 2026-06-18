// SnapshotRefName.swift
//
// The wire-stable name format for ADR 0033 snapshot refs:
//
//     refs/sprig/snapshots/<timestamp>/<op>
//
// where:
//   - `<timestamp>` is a 16-char compact ISO 8601 UTC timestamp like
//     `20260506T031234Z` (no separators, lexicographically sortable so
//     `git for-each-ref --sort=refname refs/sprig/snapshots/...` gives
//     chronological order without parsing).
//   - `<op>` is a short identifier for the destructive operation that
//     produced the snapshot (`merge`, `rebase`, `reset-hard`, etc.).
//     Lowercase ASCII letters / digits / dashes only.
//
// Tier 1, portable. No git invocation here — that's slice S2's job
// (`SnapshotWriter` calling `git update-ref`). This file is the
// canonical source of truth for the format used on both ends.

import Foundation

/// One ref under `refs/sprig/snapshots/`, decomposed into its timestamp
/// and operation tag.
///
/// **Wire-stable.** The string form (``refName``) appears in
/// snapshot-ref names on disk under `.git/refs/sprig/snapshots/...`, in
/// `Recover` task-window UIs, in `sprigctl recover --list` output, and
/// (per ADR 0033's amendment) in destructive-op task-window header
/// strips. Any change to the format is a migration: older snapshots
/// must remain parseable forever.
///
/// **Sortable.** The ``Self/timestampFormat`` is a 16-char compact
/// ISO 8601 form (`YYYYMMDDTHHMMSSZ`) chosen specifically so that
/// `git for-each-ref --sort=refname refs/sprig/snapshots/` returns
/// chronological order without further parsing.
public struct SnapshotRefName: Equatable, Hashable, Sendable {
    /// The fixed prefix every snapshot ref shares.
    public static let prefix = "refs/sprig/snapshots/"

    /// The destructive operation that created the snapshot (e.g.
    /// ``opMerge``, ``opRebase``).
    public let op: String

    /// The instant the snapshot was created. Stored as an instant on
    /// disk (rounded to one-second precision per ``timestampFormat``).
    public let timestamp: Date

    /// Construct a snapshot ref name from its components.
    ///
    /// Returns nil if `op` doesn't match the allowed shape (lowercase
    /// ASCII, digits, and dashes; first character must be a letter;
    /// 1-64 chars). The timestamp is accepted as-is but rendered to
    /// one-second resolution in ``refName``; sub-second precision is
    /// silently dropped.
    public init?(timestamp: Date, op: String) {
        guard SnapshotRefName.isValidOp(op) else { return nil }
        self.timestamp = timestamp
        self.op = op
    }

    /// The full git ref name (e.g.
    /// `refs/sprig/snapshots/20260506T031234Z/merge`).
    public var refName: String {
        "\(SnapshotRefName.prefix)\(SnapshotRefName.formatTimestamp(timestamp))/\(op)"
    }

    /// The op tag with any same-second uniquifier suffix stripped.
    ///
    /// ``SnapshotWriter`` mints same-second collisions of one op as
    /// `<op>-2`, `<op>-3`, … Consumers that classify a snapshot by
    /// matching against a known op constant — e.g. the Recover surface,
    /// which restores an ``opStashDrop`` snapshot with `git stash store`
    /// rather than the `reset --hard` every other op uses — MUST compare
    /// against `baseOp`, never the raw ``op``, or a uniquified ref
    /// (`stash-drop-2`) is misclassified and gets the wrong, possibly
    /// destructive, restore verb.
    ///
    /// No known op constant ends in `-<digits>`, so stripping a single
    /// trailing `-<one-or-more-ASCII-digits>` recovers the base
    /// unambiguously; an op without that suffix is returned unchanged.
    public var baseOp: String {
        guard let dashIndex = op.lastIndex(of: "-") else { return op }
        let suffix = op[op.index(after: dashIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy({ ("0" ... "9").contains($0) }) else { return op }
        return String(op[..<dashIndex])
    }

    /// Parse a `refs/sprig/snapshots/<ts>/<op>` ref name.
    ///
    /// Returns nil if the input doesn't have the canonical shape:
    /// the prefix, a 16-char `YYYYMMDDTHHMMSSZ` timestamp that decodes
    /// to a real date, and a single non-empty `<op>` segment matching
    /// ``isValidOp(_:)``. Trailing slashes, extra path segments, or
    /// non-conforming op strings are rejected — anything other than
    /// "exactly one snapshot ref" returns nil. Callers that get nil
    /// should either skip the ref (e.g. when iterating a `for-each-ref`
    /// listing) or surface the malformed name to diagnostics.
    public static func parse(_ refName: String) -> SnapshotRefName? {
        guard refName.hasPrefix(prefix) else { return nil }
        let suffix = refName.dropFirst(prefix.count)
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let timestampString = String(parts[0])
        let op = String(parts[1])
        guard let timestamp = parseTimestamp(timestampString) else { return nil }
        return Self(timestamp: timestamp, op: op)
    }

    // MARK: - Known operation tags

    /// `git merge` (including `merge --abort`-able mid-merge state).
    public static let opMerge = "merge"
    /// `git rebase` (interactive or non-interactive).
    public static let opRebase = "rebase"
    /// `git reset --hard <commit>`.
    public static let opResetHard = "reset-hard"
    /// `git stash drop`.
    public static let opStashDrop = "stash-drop"
    /// `git push --force-with-lease` (we never emit raw `--force`; see
    /// CLAUDE.md hard rule #7).
    public static let opForcePush = "force-push"
    /// `git cherry-pick`.
    public static let opCherryPick = "cherry-pick"
    /// `git revert`.
    public static let opRevert = "revert"
    /// Deleting an unmerged or otherwise risky branch.
    public static let opBranchDelete = "branch-delete"
    /// Switching branches with dirty working-tree changes that would
    /// otherwise be left behind.
    public static let opCheckoutDirty = "checkout-dirty"
    /// The pre-restore safety snapshot the Recover surface takes of
    /// HEAD before `reset --hard`-ing to another snapshot — a restore
    /// is itself reversible (ADR 0033 amendment).
    public static let opRestore = "restore"
    /// `git commit --amend` replacing only the message (ADR 0082).
    public static let opReword = "reword"
    /// Combining the last N commits into one (ADR 0082).
    public static let opSquash = "squash"
    /// Replaying a stacked child branch onto its moved parent
    /// (`git rebase --onto`, ADR 0085). One snapshot per replayed
    /// child, at the child's pre-restack tip.
    public static let opRestack = "restack"

    // MARK: - Format internals (exposed for tests)

    /// `YYYYMMDDTHHMMSSZ` — 16-char compact ISO 8601 in UTC. The
    /// no-separator form keeps the ref name short *and* sortable; git
    /// sorts ref names byte-by-byte, so this string sorts identically
    /// to the underlying instant.
    static let timestampFormat = "YYYYMMDDTHHMMSSZ"

    /// Render a `Date` to ``timestampFormat``. UTC, second-precision.
    static func formatTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    /// Parse ``timestampFormat``. Returns nil if the input isn't
    /// exactly 16 characters in the `YYYYMMDDTHHMMSSZ` shape *or* if
    /// the components don't form a real calendar date (e.g. month 13).
    static func parseTimestamp(_ string: String) -> Date? {
        guard string.count == 16 else { return nil }
        let chars = Array(string)
        guard chars[8] == "T", chars[15] == "Z" else { return nil }
        guard
            let year = Int(String(chars[0 ..< 4])),
            let month = Int(String(chars[4 ..< 6])),
            let day = Int(String(chars[6 ..< 8])),
            let hour = Int(String(chars[9 ..< 11])),
            let minute = Int(String(chars[11 ..< 13])),
            let second = Int(String(chars[13 ..< 15]))
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = utcTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        // `Calendar.date(from:)` *normalizes* invalid components instead
        // of rejecting them — Feb 30 rolls over to March 2, hour 25
        // becomes hour 1 the next day. To get strict validation we
        // round-trip: build the date, extract components from it, and
        // demand the extracted components match the input. Anything
        // that got normalized away returns nil here.
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard
            roundTrip.year == year,
            roundTrip.month == month,
            roundTrip.day == day,
            roundTrip.hour == hour,
            roundTrip.minute == minute,
            roundTrip.second == second
        else { return nil }
        return date
    }

    /// True if `op` is a syntactically valid operation tag for use in a
    /// snapshot ref. Restricted to `[a-z][a-z0-9-]{0,63}` so the result
    /// is safe for use as a path segment under `.git/refs/sprig/...`
    /// on every supported platform (no spaces, no slashes, no shell
    /// metacharacters, fits within filesystem limits).
    public static func isValidOp(_ op: String) -> Bool {
        guard !op.isEmpty, op.count <= 64 else { return false }
        guard let firstScalar = op.unicodeScalars.first,
              firstScalar.isASCII,
              ("a" ... "z").contains(Character(firstScalar))
        else { return false }
        return op.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            let char = Character(scalar)
            return ("a" ... "z").contains(char)
                || ("0" ... "9").contains(char)
                || char == "-"
        }
    }

    /// `nil`-safe in principle — `TimeZone(identifier: "UTC")` is
    /// valid on every platform Foundation ships on — but force-unwrap
    /// is forbidden, so fall back to `.gmt`. Both denote the same
    /// instant; UTC is just the explicit identifier we'd prefer.
    private static let utcTimeZone = TimeZone(identifier: "UTC") ?? TimeZone.gmt
}
