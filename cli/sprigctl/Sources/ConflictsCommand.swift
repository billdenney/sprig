// ConflictsCommand.swift
//
// `sprigctl conflicts` — surface ConflictKit's parser + auto-resolver
// to the CLI. Three modes, exactly one of which must be supplied:
//
//   --list [<repo>]            list unmerged paths in the repo, with
//                              the number of conflict regions each.
//   --show <file>              show every conflict region in a file.
//   --auto-resolve <file>      apply auto-resolution heuristics to the
//                              file at <path> and write back; markers
//                              remain on regions that don't resolve.
//
// Mirrors the flag-style mode-discrimination of `sprigctl recover`
// (--list / --restore) so users have one mental model across the CLI.

import ArgumentParser
import ConflictKit
import Foundation
import GitCore

struct ConflictsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conflicts",
        abstract: "List, inspect, or auto-resolve git conflict markers."
    )

    @Argument(help: "Path: repo for --list (default cwd), or file for --show / --auto-resolve.")
    var path: String?

    @Flag(name: .long, help: "List unmerged paths in the repo.")
    var list: Bool = false

    @Flag(name: .long, help: "Show conflict regions in the file at <path>.")
    var show: Bool = false

    @Flag(
        name: .customLong("auto-resolve"),
        help: "Apply auto-resolution to the file at <path> and write back."
    )
    var autoResolve: Bool = false

    @Flag(
        name: .long,
        help: "With --auto-resolve, also resolve whitespace-only differences (unsafe in Python/YAML)."
    )
    var whitespace: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary (--list / --show only).")
    var json: Bool = false

    func run() async throws {
        let activeCount = [list, show, autoResolve].filter(\.self).count
        switch activeCount {
        case 0:
            throw ValidationError(
                "specify one of --list (enumerate unmerged paths), --show (inspect one file), " +
                    "or --auto-resolve (resolve trivially-equivalent regions and write back)"
            )
        case 1:
            if !autoResolve, whitespace {
                throw ValidationError("--whitespace is only meaningful with --auto-resolve")
            }
            if list {
                try await runList()
            } else if show {
                try runShow()
            } else {
                try runAutoResolve()
            }
        default:
            throw ValidationError("--list, --show, and --auto-resolve are mutually exclusive")
        }
    }

    // MARK: - --list

    private func runList() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)
        let output = try await runner.run(["status", "--porcelain=v2", "-z"])
        let status = try PorcelainV2Parser.parse(output.stdout)

        let unmergedPaths: [String] = status.entries.compactMap { entry in
            if case let .unmerged(u) = entry { return u.path }
            return nil
        }

        // For each unmerged path, count regions in the worktree file.
        // A path may not exist on disk if the conflict is delete-vs-modify;
        // in that case region count is 0 and we still surface the path.
        let rows = unmergedPaths.map { relPath in
            ListRow(
                path: relPath,
                regions: regionCount(at: repoURL.appendingPathComponent(relPath))
            )
        }

        if json {
            try emitJSON(rows)
        } else {
            emitListHuman(rows)
        }
    }

    /// Read the file at `url` and return the number of conflict
    /// regions in it. Returns 0 if the file is missing, unreadable,
    /// or not valid UTF-8.
    private func regionCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        guard let source = String(data: data, encoding: .utf8) else { return 0 }
        return ConflictParser.parse(source).count
    }

    private func emitListHuman(_ rows: [ListRow]) {
        var out = StdoutStream()
        if rows.isEmpty {
            var err = StderrStream()
            print("# no unmerged paths in this repo", to: &err)
            return
        }
        for row in rows {
            let suffix = row.regions == 1 ? "region" : "regions"
            print("\(row.path)  (\(row.regions) \(suffix))", to: &out)
        }
    }

    // MARK: - --show

    private func runShow() throws {
        guard let path else {
            throw ValidationError("--show requires a file path argument")
        }
        let fileURL = URL(fileURLWithPath: path).standardized
        let data = try Data(contentsOf: fileURL)
        guard let source = String(data: data, encoding: .utf8) else {
            throw ValidationError("file is not valid UTF-8: \(fileURL.path)")
        }
        let regions = ConflictParser.parse(source)

        if json {
            try emitJSON(regions.map(RegionWire.init))
        } else {
            emitShowHuman(regions: regions, file: fileURL)
        }
    }

    private func emitShowHuman(regions: [ConflictRegion], file: URL) {
        var out = StdoutStream()
        if regions.isEmpty {
            var err = StderrStream()
            print("# no conflict regions in \(file.path)", to: &err)
            return
        }
        for (index, region) in regions.enumerated() {
            let baseSuffix = region.base != nil ? " (diff3)" : ""
            print(
                "region \(index + 1): lines \(region.lineRange.lowerBound)–\(region.lineRange.upperBound)" +
                    "  ours=\(region.oursLabel)  theirs=\(region.theirsLabel)\(baseSuffix)",
                to: &out
            )
            print("  ours (\(region.ours.count) line\(region.ours.count == 1 ? "" : "s")):", to: &out)
            for line in region.ours {
                print("    \(line)", to: &out)
            }
            if let base = region.base {
                print("  base (\(base.count) line\(base.count == 1 ? "" : "s")):", to: &out)
                for line in base {
                    print("    \(line)", to: &out)
                }
            }
            print("  theirs (\(region.theirs.count) line\(region.theirs.count == 1 ? "" : "s")):", to: &out)
            for line in region.theirs {
                print("    \(line)", to: &out)
            }
        }
    }

    // MARK: - --auto-resolve

    private func runAutoResolve() throws {
        guard let path else {
            throw ValidationError("--auto-resolve requires a file path argument")
        }
        let fileURL = URL(fileURLWithPath: path).standardized
        let data = try Data(contentsOf: fileURL)
        guard let source = String(data: data, encoding: .utf8) else {
            throw ValidationError("file is not valid UTF-8: \(fileURL.path)")
        }

        let file = ConflictedFile(source: source)
        var err = StderrStream()
        guard !file.isClean else {
            print("# no conflict regions in \(fileURL.path)", to: &err)
            return
        }

        var strategies: Set<AutoResolutionStrategy> = [.identical]
        if whitespace {
            strategies.insert(.whitespaceOnly)
        }
        let resolutions = file.autoResolutions(strategies: strategies)
        let unresolvedCount = resolutions.filter(Self.isUnresolved).count
        let resolvedCount = resolutions.count - unresolvedCount

        guard resolvedCount > 0 else {
            print("# no auto-resolvable regions in \(fileURL.path)", to: &err)
            return
        }

        // Apply + write atomically (write-temp-then-rename via
        // `Data.write(.atomic)` — survives a crash mid-write).
        let resolved = try file.applying(resolutions)
        try Data(resolved.utf8).write(to: fileURL, options: [.atomic])

        var out = StdoutStream()
        let total = file.regions.count
        if unresolvedCount == 0 {
            print(
                "Resolved all \(total) region\(total == 1 ? "" : "s") in \(fileURL.path)",
                to: &out
            )
        } else {
            print(
                "Resolved \(resolvedCount) of \(total) region\(total == 1 ? "" : "s") in \(fileURL.path); " +
                    "\(unresolvedCount) still need manual resolution",
                to: &out
            )
        }
    }

    /// Predicate matching `ConflictResolution.unresolved`. A free
    /// helper so the call site reads as `filter(Self.isUnresolved)`
    /// instead of inlining the case-pattern closure.
    private static func isUnresolved(_ resolution: ConflictResolution) -> Bool {
        if case .unresolved = resolution { return true }
        return false
    }

    // MARK: - Shared JSON

    private func emitJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let text = String(data: data, encoding: .utf8) {
            var out = StdoutStream()
            print(text, to: &out)
        }
    }
}

// MARK: - Wire formats

private struct ListRow: Encodable {
    let path: String
    let regions: Int
}

private struct RegionWire: Encodable {
    let oursLabel: String
    let baseLabel: String?
    let theirsLabel: String
    let ours: [String]
    let base: [String]?
    let theirs: [String]
    let startLine: Int
    let endLine: Int

    init(_ region: ConflictRegion) {
        self.oursLabel = region.oursLabel
        self.baseLabel = region.baseLabel
        self.theirsLabel = region.theirsLabel
        self.ours = region.ours
        self.base = region.base
        self.theirs = region.theirs
        self.startLine = region.lineRange.lowerBound
        self.endLine = region.lineRange.upperBound
    }
}
