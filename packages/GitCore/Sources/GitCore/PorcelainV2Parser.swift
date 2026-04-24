// PorcelainV2Parser — byte-level parser for `git status --porcelain=v2 -z`.
//
// The parser is intentionally byte-oriented: git's porcelain-v2 format with
// `-z` NUL-terminates each record and leaves paths unquoted, so decoding
// happens at the path boundary rather than on the whole buffer. Path bytes
// are decoded as UTF-8 with invalid-sequence replacement for now; a raw-byte
// path representation is a planned follow-up when we hit a non-UTF-8 repo in
// the wild (tracked in Round 9 questions).

import Foundation

public enum PorcelainV2Parser {
    /// Parse NUL-separated porcelain-v2 output into a typed status model.
    ///
    /// - Parameter data: the raw stdout bytes from `git status --porcelain=v2 -z`.
    /// - Throws: ``GitError.parseFailure`` on malformed input.
    public static func parse(_ data: Data) throws -> PorcelainV2Status {
        var result = PorcelainV2Status()
        var records = RecordIterator(data: data)

        while let record = records.next() {
            if record.isEmpty { continue }

            if record.hasPrefix("# ") {
                try applyHeader(record, to: &result)
                continue
            }

            // Entry lines start with a one-char prefix followed by a space,
            // except the single-char-prefix forms like `? path` and `! path`.
            let first = record.first!
            switch first {
            case "1":
                try result.entries.append(.ordinary(parseOrdinary(record)))
            case "2":
                // Type-2 entries are followed by an extra NUL-terminated record
                // for the original path. Consume it here.
                let orig = records.next() ?? ""
                try result.entries.append(
                    .renamed(parseRenamed(record, origPath: orig))
                )
            case "u":
                try result.entries.append(.unmerged(parseUnmerged(record)))
            case "?":
                result.entries.append(.untracked(path: pathAfterPrefix(record)))
            case "!":
                result.entries.append(.ignored(path: pathAfterPrefix(record)))
            default:
                throw GitError.parseFailure(
                    context: "porcelain-v2 entry prefix",
                    rawSnippet: String(record.prefix(40))
                )
            }
        }

        return result
    }

    // MARK: - Header parsing

    private static func applyHeader(
        _ record: String,
        to result: inout PorcelainV2Status
    ) throws {
        // Strip "# " and split into at most two components.
        let body = record.dropFirst(2)
        let components = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = components.first else { return }

        let value = components.count > 1 ? String(components[1]) : ""

        switch key {
        case "branch.oid":
            var branch = result.branch ?? BranchInfo()
            branch.oid = value == "(initial)" ? nil : value
            result.branch = branch

        case "branch.head":
            var branch = result.branch ?? BranchInfo()
            branch.head = value == "(detached)" ? nil : value
            result.branch = branch

        case "branch.upstream":
            var branch = result.branch ?? BranchInfo()
            branch.upstream = value.isEmpty ? nil : value
            result.branch = branch

        case "branch.ab":
            // Format: "+<ahead> -<behind>"
            let parts = value.split(separator: " ")
            guard parts.count == 2,
                  parts[0].hasPrefix("+"),
                  parts[1].hasPrefix("-"),
                  let ahead = Int(parts[0].dropFirst()),
                  let behind = Int(parts[1].dropFirst())
            else {
                throw GitError.parseFailure(
                    context: "branch.ab header",
                    rawSnippet: record
                )
            }
            var branch = result.branch ?? BranchInfo()
            branch.ahead = ahead
            branch.behind = behind
            result.branch = branch

        case "stash":
            guard let count = Int(value) else {
                throw GitError.parseFailure(
                    context: "stash header",
                    rawSnippet: record
                )
            }
            result.stashCount = count

        default:
            // Unknown headers are tolerated — git can add new ones.
            break
        }
    }

    // MARK: - Entry parsing

    /// Format: `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ record: String) throws -> Ordinary {
        let body = record.dropFirst(2) // drop "1 "
        let tokens = body.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false)
        guard tokens.count == 8 else {
            throw GitError.parseFailure(
                context: "ordinary entry (expected 8 fields)",
                rawSnippet: record
            )
        }
        return try Ordinary(
            xy: parseXY(String(tokens[0]), in: record),
            submodule: parseSubmoduleState(String(tokens[1]), in: record),
            modeHead: parseMode(String(tokens[2]), in: record),
            modeIndex: parseMode(String(tokens[3]), in: record),
            modeWorktree: parseMode(String(tokens[4]), in: record),
            hashHead: String(tokens[5]),
            hashIndex: String(tokens[6]),
            path: String(tokens[7])
        )
    }

    /// Format: `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` (+ separate origPath record)
    private static func parseRenamed(_ record: String, origPath: String) throws -> Renamed {
        let body = record.dropFirst(2) // drop "2 "
        let tokens = body.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard tokens.count == 9 else {
            throw GitError.parseFailure(
                context: "renamed entry (expected 9 fields)",
                rawSnippet: record
            )
        }
        let opScore = String(tokens[7])
        guard let opChar = opScore.first,
              let op = RenameOp(rawValue: opChar),
              let score = Int(opScore.dropFirst())
        else {
            throw GitError.parseFailure(
                context: "renamed entry <X><score>",
                rawSnippet: record
            )
        }
        return try Renamed(
            xy: parseXY(String(tokens[0]), in: record),
            submodule: parseSubmoduleState(String(tokens[1]), in: record),
            modeHead: parseMode(String(tokens[2]), in: record),
            modeIndex: parseMode(String(tokens[3]), in: record),
            modeWorktree: parseMode(String(tokens[4]), in: record),
            hashHead: String(tokens[5]),
            hashIndex: String(tokens[6]),
            op: op,
            score: score,
            path: String(tokens[8]),
            origPath: origPath
        )
    }

    /// Format: `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private static func parseUnmerged(_ record: String) throws -> Unmerged {
        let body = record.dropFirst(2) // drop "u "
        let tokens = body.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard tokens.count == 10 else {
            throw GitError.parseFailure(
                context: "unmerged entry (expected 10 fields)",
                rawSnippet: record
            )
        }
        return try Unmerged(
            xy: parseXY(String(tokens[0]), in: record),
            submodule: parseSubmoduleState(String(tokens[1]), in: record),
            modeStage1: parseMode(String(tokens[2]), in: record),
            modeStage2: parseMode(String(tokens[3]), in: record),
            modeStage3: parseMode(String(tokens[4]), in: record),
            modeWorktree: parseMode(String(tokens[5]), in: record),
            hashStage1: String(tokens[6]),
            hashStage2: String(tokens[7]),
            hashStage3: String(tokens[8]),
            path: String(tokens[9])
        )
    }

    // MARK: - Field parsing

    private static func parseXY(_ raw: String, in record: String) throws -> StatusXY {
        guard raw.count == 2 else {
            throw GitError.parseFailure(
                context: "XY status (expected 2 chars, got '\(raw)')",
                rawSnippet: record
            )
        }
        let chars = Array(raw)
        guard let x = StatusCode(rawValue: chars[0]),
              let y = StatusCode(rawValue: chars[1])
        else {
            throw GitError.parseFailure(
                context: "XY status unrecognized code '\(raw)'",
                rawSnippet: record
            )
        }
        return StatusXY(index: x, worktree: y)
    }

    private static func parseSubmoduleState(_ raw: String, in record: String) throws -> SubmoduleState {
        guard raw.count == 4 else {
            throw GitError.parseFailure(
                context: "submodule state (expected 4 chars, got '\(raw)')",
                rawSnippet: record
            )
        }
        let chars = Array(raw)
        if chars[0] == "N" {
            return .notSubmodule
        }
        guard chars[0] == "S" else {
            throw GitError.parseFailure(
                context: "submodule state leading char '\(chars[0])'",
                rawSnippet: record
            )
        }
        return SubmoduleState(
            isSubmodule: true,
            commitChanged: chars[1] == "C",
            trackedModified: chars[2] == "M",
            untrackedModified: chars[3] == "U"
        )
    }

    private static func parseMode(_ raw: String, in record: String) throws -> UInt32 {
        guard let mode = UInt32(raw, radix: 8) else {
            throw GitError.parseFailure(
                context: "octal mode '\(raw)'",
                rawSnippet: record
            )
        }
        return mode
    }

    private static func pathAfterPrefix(_ record: String) -> String {
        // `? path` / `! path` — drop the two-char prefix.
        String(record.dropFirst(2))
    }
}

// MARK: - NUL-separated record iterator

/// Walks a byte buffer, yielding each NUL-terminated record as a UTF-8 string.
/// A trailing NUL (common in porcelain-v2) produces no empty final record.
private struct RecordIterator {
    private let data: Data
    private var cursor: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func next() -> String? {
        guard cursor < data.count else { return nil }
        let start = cursor
        while cursor < data.count, data[cursor] != 0 {
            cursor += 1
        }
        let slice = data[start ..< cursor]
        // Advance past the NUL (if present).
        if cursor < data.count { cursor += 1 }
        // Use `String(decoding:as:)` (non-failable, replaces invalid UTF-8
        // with U+FFFD) rather than `String(bytes:encoding:)` — git paths are
        // raw bytes and we want a best-effort string for display even when
        // not valid UTF-8. See docs/architecture/git-backend.md.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: slice, as: UTF8.self)
    }
}
