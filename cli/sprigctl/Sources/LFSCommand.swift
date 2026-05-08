// LFSCommand.swift
//
// `sprigctl lfs` — surfaces LFSKit's install probe + .gitattributes
// scanner + per-file pointer detection to the CLI. Mirrors
// `sprigctl conflicts`'s flag-style mode discrimination so users
// have one mental model across the CLI:
//
// - `--status [<repo>]` — install state + LFS-tracked patterns.
// - `--check <file> [<repo>]` — per-file LFS-tracked + pointer
//   detection. Combines `LFSAttributeChecker` (authoritative
//   answer to "is this path LFS-tracked?") with `LFSPointerParser`
//   (is the file *content* a git-lfs pointer?). The two are
//   independent — a tracked file may not yet be smudged (no
//   pointer despite tracked status); an untracked file may carry
//   a leftover pointer from a previous configuration.

import ArgumentParser
import Foundation
import GitCore
import LFSKit

struct LFSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lfs",
        abstract: "Inspect git-lfs install state, LFS-tracked patterns, and per-file LFS status."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "Show install state and LFS-tracked patterns.")
    var status: Bool = false

    @Option(name: .long, help: "Inspect a single file: report LFS-tracked status and whether the file content is a git-lfs pointer.")
    var check: String?

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        switch (status, check) {
        case (true, .some):
            throw ValidationError("--status and --check are mutually exclusive")
        case (false, .none):
            throw ValidationError(
                "specify --status to inspect git-lfs state, or --check <file> to inspect a single file"
            )
        case (true, .none):
            try await runStatus()
        case (false, let .some(target)):
            try await runCheck(target: target)
        }
    }

    private func runStatus() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)

        // `LFSInstall.probe` distinguishes "git-lfs not installed"
        // (returned as fields on the status struct — fine, that's
        // what we report) from "git itself isn't usable" (thrown as
        // `LFSProbeError.gitNotAvailable`). Re-throw the latter as
        // a CLI-level validation error so the user sees a usable
        // diagnostic instead of a Swift backtrace.
        let install: LFSInstallStatus
        do {
            install = try await LFSInstall.probe(runner: runner)
        } catch let error as LFSProbeError {
            throw ValidationError(String(describing: error))
        }
        let rules = readLFSRules(repoURL: repoURL)

        if json {
            try emitJSON(install: install, rules: rules)
        } else {
            emitHuman(install: install, rules: rules)
        }
    }

    /// Read `.gitattributes` from the repo root and extract LFS
    /// rules. Returns `[]` for a missing / unreadable / non-UTF-8
    /// file — repos without a `.gitattributes` are common (no LFS
    /// configured) and not an error.
    private func readLFSRules(repoURL: URL) -> [LFSAttributeRule] {
        let attributesURL = repoURL.appendingPathComponent(".gitattributes")
        guard let data = try? Data(contentsOf: attributesURL) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return GitAttributesLFSParser.extractLFSRules(text)
    }

    // MARK: - Human output

    private func emitHuman(install: LFSInstallStatus, rules: [LFSAttributeRule]) {
        var out = StdoutStream()
        let binaryLine = install.binaryVersion.map { "installed (\($0))" } ?? "not installed"
        print("git-lfs:    \(binaryLine)", to: &out)
        print("configured: \(install.configured ? "yes" : "no")", to: &out)
        print("ready:      \(install.isReady ? "yes" : "no")", to: &out)

        if rules.isEmpty {
            print("tracked:    no LFS rules in .gitattributes", to: &out)
        } else {
            let plural = rules.count == 1 ? "" : "s"
            print(
                "tracked:    \(rules.count) LFS pattern\(plural) in .gitattributes",
                to: &out
            )
            for rule in rules {
                print("  \(rule.pattern)  (line \(rule.lineNumber))", to: &out)
            }
        }
    }

    // MARK: - JSON output

    private func emitJSON(install: LFSInstallStatus, rules: [LFSAttributeRule]) throws {
        let wire = LFSStatusWire(install: install, rules: rules)
        try emitWireJSON(wire)
    }

    // MARK: - --check

    private func runCheck(target: String) async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)

        // Resolve `target` against the repo root if relative; absolute
        // paths pass through. We pass the *original* target string to
        // git so its check-attr output echoes the same shape (relative
        // for relative inputs), but we use the resolved file URL for
        // disk reads so we don't depend on the process cwd.
        let fileURL: URL = if (target as NSString).isAbsolutePath {
            URL(fileURLWithPath: target).standardized
        } else {
            repoURL.appendingPathComponent(target).standardized
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            throw ValidationError("path not found: \(target)")
        }
        if isDir.boolValue {
            throw ValidationError("path is a directory, expected a file: \(target)")
        }

        // Authoritative LFS-tracked answer comes from git itself.
        let attrResults = try await LFSAttributeChecker.check(paths: [target], runner: runner)
        let attr = attrResults.first ?? LFSCheckAttrResult(path: target, filter: "unspecified")

        // Pointer detection: bound the read to `maxPointerByteCount` so
        // we never load multi-megabyte real-content files just to
        // confirm they aren't pointers. Files larger than the cap can't
        // be pointers.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let fileSize = (attrs[.size] as? Int) ?? 0
        let pointer: LFSPointer?
        if fileSize > LFSPointerParser.maxPointerByteCount {
            pointer = nil
        } else {
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            pointer = parsePointer(from: data)
        }

        let wire = LFSCheckWire(target: target, attr: attr, fileSize: fileSize, pointer: pointer)
        if json {
            try emitWireJSON(wire)
        } else {
            emitCheckHuman(wire)
        }
    }

    private func parsePointer(from data: Data) -> LFSPointer? {
        guard LFSPointerParser.isLikelyPointer(data) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return LFSPointerParser.parse(text)
    }

    private func emitCheckHuman(_ wire: LFSCheckWire) {
        var out = StdoutStream()
        print("path:    \(wire.target)", to: &out)
        let trackedLabel = wire.isLFSTracked ? "yes" : "no"
        print("tracked: \(trackedLabel) (filter=\(wire.filter))", to: &out)
        if let pointer = wire.pointer {
            print("content: pointer", to: &out)
            print("  oid:   \(pointer.oidSHA256)", to: &out)
            print("  size:  \(pointer.size) bytes", to: &out)
            if !wire.isLFSTracked {
                print("note:    pointer present but path is not LFS-tracked (leftover)", to: &out)
            }
        } else {
            print("content: not a pointer (\(wire.fileSize) bytes on disk)", to: &out)
            if wire.isLFSTracked {
                print("note:    LFS-tracked but no pointer — content not yet smudged or LFS not installed", to: &out)
            }
        }
    }

    private func emitWireJSON(_ wire: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(wire)
        if let text = String(data: data, encoding: .utf8) {
            var out = StdoutStream()
            print(text, to: &out)
        }
    }
}

// MARK: - JSON wire format

/// Same pattern as the other sprigctl JSON outputs: a dedicated wire
/// struct so the CLI's JSON contract can evolve independently of
/// LFSKit's internal types.
private struct LFSStatusWire: Encodable {
    struct Rule: Encodable {
        let pattern: String
        let lineNumber: Int
    }

    let binaryAvailable: Bool
    let binaryVersion: String?
    let configured: Bool
    let isReady: Bool
    let trackedPatterns: [Rule]

    init(install: LFSInstallStatus, rules: [LFSAttributeRule]) {
        self.binaryAvailable = install.binaryAvailable
        self.binaryVersion = install.binaryVersion
        self.configured = install.configured
        self.isReady = install.isReady
        self.trackedPatterns = rules.map { Rule(pattern: $0.pattern, lineNumber: $0.lineNumber) }
    }
}

/// `--check` wire format. `isLFSTracked` is the boolean callers care
/// about; `filter` is the raw `git check-attr` value (`"lfs"`,
/// `"unspecified"`, `"unset"`, or any custom filter driver name) for
/// users who need the distinction.
struct LFSCheckWire: Encodable {
    struct Pointer: Encodable {
        let version: String
        let oidSHA256: String
        let size: Int
    }

    let target: String
    let filter: String
    let isLFSTracked: Bool
    let isPointerFile: Bool
    let pointer: Pointer?
    let fileSize: Int

    init(target: String, attr: LFSCheckAttrResult, fileSize: Int, pointer: LFSPointer?) {
        self.target = target
        self.filter = attr.filter
        self.isLFSTracked = attr.isLFS
        self.isPointerFile = pointer != nil
        self.pointer = pointer.map {
            Pointer(version: $0.version, oidSHA256: $0.oidSHA256, size: $0.size)
        }
        self.fileSize = fileSize
    }
}
