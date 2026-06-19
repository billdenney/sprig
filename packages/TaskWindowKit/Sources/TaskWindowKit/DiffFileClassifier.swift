// DiffFileClassifier.swift
//
// ADR 0086 C0 — the async orchestration that fills ``ClassifiedDiffFile``
// for a diff target: run `git diff --numstat -z` (binary marker + line
// counts), `git check-attr` (diff/merge drivers), and a per-file
// content sniff of the new-side bytes (resolving an LFS pointer to its
// real blob first), then route each file to a renderer.
//
// Lives in TaskWindowKit (not GitCore) because it combines GitCore's
// diff primitives with LFSKit's pointer detection — GitCore can't depend
// on LFSKit.
//
// Tier 1, portable.

import Foundation
import GitCore
import LFSKit

enum DiffFileClassifier {
    /// Classify every changed file for `target`.
    static func classify(
        target: DiffTarget,
        repoURL: URL,
        runner: Runner
    ) async throws -> [ClassifiedDiffFile] {
        let numstat = try await DiffNumstat.entries(
            runner: runner,
            baseArguments: DiffViewerViewModel.gitArguments(for: target)
        )
        guard !numstat.isEmpty else { return [] }

        let drivers = try await GitAttributeDrivers.query(paths: numstat.map(\.path), runner: runner)
        let driverByPath = Dictionary(drivers.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        let catFile = try? await CatFileBatch(repoURL: repoURL)
        defer { if let catFile { Task { await catFile.close() } } }

        var result: [ClassifiedDiffFile] = []
        for entry in numstat {
            await result.append(classify(
                entry,
                target: target,
                repoURL: repoURL,
                driver: driverByPath[entry.path],
                catFile: catFile
            ))
        }
        return result
    }

    private static func classify(
        _ entry: NumstatEntry,
        target: DiffTarget,
        repoURL: URL,
        driver: AttributeDrivers?,
        catFile: CatFileBatch?
    ) async -> ClassifiedDiffFile {
        let header = await newSideHeader(path: entry.path, target: target, repoURL: repoURL, catFile: catFile)
        let lfsPointer = parsePointer(header)
        let contentType: ContentType = if let lfsPointer {
            // Resolve the pointer to the real media and sniff THAT, so the
            // type reflects the content, not the ~130-byte pointer text.
            // The LFS object is content-addressed under .git/lfs/objects/
            // — NOT a git object (its oid is a content sha256, not a git
            // sha1), so it's read from LFS storage, not cat-file. Absent
            // when the object hasn't been fetched → unknown binary.
            if let bytes = resolveLFSObject(oid: lfsPointer.oidSHA256, repoURL: repoURL) {
                ContentTypeSniffer.sniff(bytes)
            } else {
                .unknownBinary
            }
        } else if let header {
            ContentTypeSniffer.sniff(header)
        } else {
            // No readable new side (e.g. a deletion): fall back to git's
            // own binary marker.
            entry.isBinary ? .unknownBinary : .plainText
        }

        let renderer = DiffRendererKind.route(
            path: entry.path,
            contentType: contentType,
            diffDriver: driver?.diff,
            // An LFS pointer's numstat row is text (the pointer is text),
            // but its real content is binary — so treat it as binary for
            // routing.
            isBinary: entry.isBinary || lfsPointer != nil
        )
        return ClassifiedDiffFile(
            path: entry.path,
            oldPath: entry.oldPath,
            added: entry.added,
            deleted: entry.deleted,
            isBinary: entry.isBinary,
            contentType: contentType,
            diffDriver: driver?.diff,
            mergeDriver: driver?.merge,
            lfsPointer: lfsPointer,
            renderer: renderer
        )
    }

    /// Parse `header` as an LFS pointer, or nil if it isn't one.
    private static func parsePointer(_ header: Data?) -> LFSPointer? {
        guard let header, LFSPointerParser.isLikelyPointer(header) else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return LFSPointerParser.parse(String(decoding: header, as: UTF8.self))
    }

    /// Read up to a sniff window of the file's NEW-side bytes for the
    /// given target — the worktree file on disk, the index blob, or the
    /// commit blob. Returns nil when there's no readable new side.
    private static func newSideHeader(
        path: String,
        target: DiffTarget,
        repoURL: URL,
        catFile: CatFileBatch?
    ) async -> Data? {
        let objectName: String
        switch target {
        case .worktreeAgainstIndex:
            let url = repoURL.appendingPathComponent(path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: ContentTypeSniffer.sniffByteCount)
        case .indexAgainstHead:
            objectName = ":\(path)"
        case let .commit(sha):
            objectName = "\(sha):\(path)"
        }
        guard let catFile, let object = try? await catFile.read(objectName) else { return nil }
        return Data(object.content.prefix(ContentTypeSniffer.sniffByteCount))
    }

    /// Read up to a sniff window of an LFS object from local LFS storage
    /// (`.git/lfs/objects/<oid[0:2]>/<oid[2:4]>/<oid>`). Returns nil when
    /// the object hasn't been fetched. (Non-standard gitdir layouts —
    /// linked worktrees, submodules — are a deferred edge.)
    private static func resolveLFSObject(oid: String, repoURL: URL) -> Data? {
        guard oid.count >= 4, oid.allSatisfy(\.isHexDigit) else { return nil }
        let prefix1 = String(oid.prefix(2))
        let prefix2 = String(oid.dropFirst(2).prefix(2))
        let object = repoURL.appendingPathComponent(".git/lfs/objects/\(prefix1)/\(prefix2)/\(oid)")
        guard let handle = try? FileHandle(forReadingFrom: object) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: ContentTypeSniffer.sniffByteCount)
    }
}
