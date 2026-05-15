// UnmergedListing.swift
//
// Parser for `git ls-files -u -z` output — the canonical way to ask
// git "which paths are currently in conflict, and what are their per-
// stage SHAs / modes?". Used by M4 MergeConflictResolver to classify
// each unmerged path into the right resolution flow (text vs binary
// vs submodule vs add-add).
//
// Wire format from `git ls-files -u -z`:
//
//     <mode> SP <sha> SP <stage> TAB <path> NUL
//
// where:
//   - <mode> is a 6-digit octal mode (e.g. 100644 for a normal file,
//     160000 for a submodule, 120000 for a symlink)
//   - <stage> is 1 (base/ancestor), 2 (ours/HEAD), or 3 (theirs)
//
// One line per stage per path: a typical 3-way conflict emits three
// lines for the same path; an add/add conflict (no common ancestor)
// emits two lines (stages 2 and 3 only).
//
// To invoke the matching git command:
//
// ```
// git ls-files -u -z
// ```
//
// The parser groups stage lines into one ``UnmergedEntry`` per path,
// preserving the input order of paths (git emits stages in 1/2/3
// order under a given path so callers can rely on the same).

import Foundation

/// Pure parser for `git ls-files -u -z` output.
public enum UnmergedListing {
    /// Parse the raw bytes of `git ls-files -u -z` into one
    /// ``UnmergedEntry`` per conflicted path. Returns an empty array
    /// for clean trees (the command emits nothing in that case).
    /// Throws ``GitError/parseFailure`` on malformed entries.
    public static func parse(_ data: Data) throws -> [UnmergedEntry] {
        var entriesByPath: [String: [UnmergedStage]] = [:]
        var pathOrder: [String] = []

        let nul: UInt8 = 0x00
        var index = data.startIndex
        while index < data.endIndex {
            let recordEnd = data[index...].firstIndex(of: nul) ?? data.endIndex
            let slice = data[index ..< recordEnd]
            if !slice.isEmpty {
                let (path, stage) = try parseRecord(Data(slice))
                if entriesByPath[path] == nil {
                    pathOrder.append(path)
                    entriesByPath[path] = []
                }
                entriesByPath[path]?.append(stage)
            }
            index = recordEnd < data.endIndex ? data.index(after: recordEnd) : data.endIndex
        }

        return pathOrder.map { path in
            UnmergedEntry(path: path, stages: entriesByPath[path] ?? [])
        }
    }

    /// Internal record-fields holder. Avoids a 4-tuple return (which
    /// trips SwiftLint's large_tuple rule) while keeping the
    /// splitter cleanly separate from the typed conversions.
    private struct RecordFields {
        let mode: String
        let sha: String
        let stage: String
        let path: String
    }

    /// Parse one `<mode> SP <sha> SP <stage> TAB <path>` record.
    private static func parseRecord(_ record: Data) throws -> (path: String, stage: UnmergedStage) {
        let fields = try splitRecordFields(record)
        guard let modeRaw = UInt32(fields.mode, radix: 8) else {
            throw GitError.parseFailure(
                context: "ls-files unmerged record mode '\(fields.mode)' isn't octal",
                rawSnippet: fields.mode
            )
        }
        guard let stageNumber = Int(fields.stage), (1 ... 3).contains(stageNumber) else {
            throw GitError.parseFailure(
                context: "ls-files unmerged record stage '\(fields.stage)' must be 1, 2, or 3",
                rawSnippet: fields.stage
            )
        }
        let stage = UnmergedStage(
            stage: stageNumber,
            mode: GitFileMode(rawMode: modeRaw),
            sha: fields.sha
        )
        return (fields.path, stage)
    }

    /// Split a single record into its four string fields by the
    /// canonical SP/SP/TAB delimiters. Kept separate so `parseRecord`
    /// stays under the function-body-length lint while the typed
    /// conversions live alongside their errors.
    private static func splitRecordFields(_ record: Data) throws -> RecordFields {
        let space: UInt8 = 0x20
        let tab: UInt8 = 0x09
        func fail(_ context: String) -> GitError {
            let snippet = String(data: record.prefix(80), encoding: .utf8) ?? "<non-UTF-8>"
            return .parseFailure(context: context, rawSnippet: snippet)
        }
        guard let firstSpace = record.firstIndex(of: space) else {
            throw fail("ls-files unmerged record missing first SP")
        }
        let afterFirstSpace = record.index(after: firstSpace)
        guard let secondSpace = record[afterFirstSpace...].firstIndex(of: space) else {
            throw fail("ls-files unmerged record missing second SP")
        }
        let afterSecondSpace = record.index(after: secondSpace)
        guard let tabIndex = record[afterSecondSpace...].firstIndex(of: tab) else {
            throw fail("ls-files unmerged record missing TAB before path")
        }
        guard
            let mode = String(data: record[..<firstSpace], encoding: .utf8),
            let sha = String(data: record[afterFirstSpace ..< secondSpace], encoding: .utf8),
            let stage = String(data: record[afterSecondSpace ..< tabIndex], encoding: .utf8),
            let path = String(data: record[record.index(after: tabIndex)...], encoding: .utf8)
        else {
            throw GitError.parseFailure(
                context: "ls-files unmerged record contained non-UTF-8 bytes",
                rawSnippet: "<non-UTF-8>"
            )
        }
        return RecordFields(mode: mode, sha: sha, stage: stage, path: path)
    }
}

/// One conflicted path with its 1–3 stage entries.
///
/// Stages: 1 = base/common ancestor (absent for add/add conflicts),
/// 2 = ours/HEAD, 3 = theirs/incoming. The MergeConflictResolver
/// (M4) UI inspects each stage's mode + SHA to decide the right
/// resolution affordance per ``ConflictKit.ConflictKind``.
public struct UnmergedEntry: Sendable, Equatable {
    /// File path the conflict is at, relative to the repo root.
    public let path: String

    /// Stage entries for this path, in the order git emitted them
    /// (typically 1 → 2 → 3 within a path, but the parser doesn't
    /// reorder so consumers can detect anomalies if any).
    public let stages: [UnmergedStage]

    public init(path: String, stages: [UnmergedStage]) {
        self.path = path
        self.stages = stages
    }

    /// The base/ancestor stage, or `nil` for an add/add conflict.
    public var baseStage: UnmergedStage? {
        stages.first { $0.stage == 1 }
    }

    /// The "ours" / HEAD-side stage, or `nil` for a
    /// `we-deleted-but-they-modified` conflict (rare).
    public var oursStage: UnmergedStage? {
        stages.first { $0.stage == 2 }
    }

    /// The "theirs" / incoming-side stage, or `nil` for a
    /// `we-modified-but-they-deleted` conflict (rare).
    public var theirsStage: UnmergedStage? {
        stages.first { $0.stage == 3 }
    }

    /// True if no base stage is present — both sides added a file at
    /// this path with no common ancestor (the canonical add/add
    /// conflict). Useful for routing this entry to its UI affordance.
    public var isAddAdd: Bool {
        baseStage == nil
    }

    /// True if any stage represents a submodule (gitlink, mode
    /// 160000). Routes to the submodule-conflict UI affordance.
    public var hasSubmoduleStage: Bool {
        stages.contains { $0.mode == .submodule }
    }
}

/// One stage line within an ``UnmergedEntry``.
public struct UnmergedStage: Sendable, Equatable {
    /// Stage number: 1 (base), 2 (ours), 3 (theirs).
    public let stage: Int

    /// File mode of this stage's blob. 100644 for a normal file,
    /// 100755 for an executable, 120000 for a symlink, 160000 for a
    /// submodule (gitlink).
    public let mode: GitFileMode

    /// Object SHA of this stage's blob (or commit SHA for a
    /// submodule stage).
    public let sha: String

    public init(stage: Int, mode: GitFileMode, sha: String) {
        self.stage = stage
        self.mode = mode
        self.sha = sha
    }
}

/// A git tree-entry mode, typed. Covers the modes git emits for
/// blobs, symlinks, and submodules; anything else (e.g. legacy
/// 100664) round-trips through ``unknown``.
public enum GitFileMode: Sendable, Equatable, Hashable {
    /// Regular file (mode 100644).
    case regularFile

    /// Executable file (mode 100755).
    case executable

    /// Symlink (mode 120000).
    case symlink

    /// Submodule / gitlink (mode 160000). The stage's `sha` is a
    /// commit SHA in the submodule's repo, not a blob SHA.
    case submodule

    /// Anything we don't have a typed case for. Round-trips the raw
    /// octal mode for diagnostics.
    case unknown(UInt32)

    public init(rawMode: UInt32) {
        switch rawMode {
        case 0o100644: self = .regularFile
        case 0o100755: self = .executable
        case 0o120000: self = .symlink
        case 0o160000: self = .submodule
        default: self = .unknown(rawMode)
        }
    }

    /// Raw octal mode — what git emits.
    public var rawMode: UInt32 {
        switch self {
        case .regularFile: 0o100644
        case .executable: 0o100755
        case .symlink: 0o120000
        case .submodule: 0o160000
        case let .unknown(value): value
        }
    }
}
