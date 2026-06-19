// ClassifiedDiffFile.swift
//
// ADR 0086 C0 — the per-file classification a diff view needs to route
// each changed file to the right renderer (the renderers themselves are
// C1/C2/C3). Combines the three detection legs — git's numstat binary
// marker, the `.gitattributes` `diff=`/`merge=` driver, and a
// magic-number content sniff — plus LFS-pointer resolution, into one
// value per file.
//
// Tier 1, portable. Pure value types + the routing decision; the async
// orchestration that fills them lives in ``DiffFileClassifier``.

import Foundation
import GitCore
import LFSKit

/// Which renderer a changed file should route to. The C1/C2/C3 renderers
/// consume this; C0 only computes it.
public enum DiffRendererKind: Sendable, Equatable {
    /// Plain text / code — the existing unified-diff renderer.
    case text
    /// A raster/vector image git treats as binary.
    case image(ContentType)
    /// A PDF document (page-by-page raster compare, deferred).
    case pdf
    /// An Office document (a ZIP container — `.docx`/`.xlsx`/`.pptx`).
    case office
    /// A Jupyter notebook (`.ipynb`, JSON text — cell diff, deferred).
    case notebook
    /// Column-aware tabular data (`.csv`/`.tsv`).
    case csv
    /// A `.gitattributes` `diff=<driver>` is configured — defer to git's
    /// external tool (ADR 0027).
    case externalTool(driver: String)
    /// Unknown binary — metadata diff + the external-tool offer.
    case binary
}

/// One changed file, classified for rendering.
public struct ClassifiedDiffFile: Sendable, Equatable {
    public let path: String
    public let oldPath: String?
    /// Added lines, or nil when git marked the file binary.
    public let added: Int?
    /// Deleted lines, or nil when git marked the file binary.
    public let deleted: Int?
    /// git's own numstat binary marker.
    public let isBinary: Bool
    /// Magic-number content type of the new side (the resolved blob when
    /// the file is an LFS pointer).
    public let contentType: ContentType
    /// Configured `diff=` driver, if any.
    public let diffDriver: String?
    /// Configured `merge=` driver, if any.
    public let mergeDriver: String?
    /// The parsed LFS pointer when the new side is one (so the UI can
    /// show real size / oid rather than the 130-byte pointer).
    public let lfsPointer: LFSPointer?
    /// The renderer this file routes to.
    public let renderer: DiffRendererKind

    public init(
        path: String,
        oldPath: String?,
        added: Int?,
        deleted: Int?,
        isBinary: Bool,
        contentType: ContentType,
        diffDriver: String?,
        mergeDriver: String?,
        lfsPointer: LFSPointer?,
        renderer: DiffRendererKind
    ) {
        self.path = path
        self.oldPath = oldPath
        self.added = added
        self.deleted = deleted
        self.isBinary = isBinary
        self.contentType = contentType
        self.diffDriver = diffDriver
        self.mergeDriver = mergeDriver
        self.lfsPointer = lfsPointer
        self.renderer = renderer
    }
}

extension DiffRendererKind {
    /// Route a file to a renderer. A configured `diff=` driver wins
    /// (defer-to-git). Otherwise git's own binary marker is the
    /// authority: a magic-number content type is only trusted when git
    /// (or an LFS pointer) also says the file is binary — so a text file
    /// that merely *starts* with `%PDF-` / `PK\x03\x04` still diffs as
    /// text. `isBinary` is the effective marker (git's numstat `-`/`-`
    /// OR an LFS pointer, whose real content is binary).
    static func route(path: String, contentType: ContentType, diffDriver: String?, isBinary: Bool) -> DiffRendererKind {
        if let diffDriver { return .externalTool(driver: diffDriver) }
        // git says text → diff as text regardless of a magic false
        // positive.
        guard isBinary else { return textRoute(path) }
        switch contentType {
        case .png, .jpeg, .gif, .webp:
            return .image(contentType)
        case .pdf:
            return .pdf
        case .zipContainer:
            return isOfficeExtension(path) ? .office : .binary
        case .unknownBinary:
            return .binary
        case .plainText:
            // git marked it binary despite a text-looking header (a NUL
            // past the sniff window, or a `binary` gitattribute).
            return .binary
        }
    }

    /// Route a text file by extension.
    private static func textRoute(_ path: String) -> DiffRendererKind {
        switch fileExtension(path) {
        case "ipynb": .notebook
        case "csv", "tsv": .csv
        default: .text
        }
    }

    private static func isOfficeExtension(_ path: String) -> Bool {
        ["docx", "xlsx", "pptx"].contains(fileExtension(path))
    }

    private static func fileExtension(_ path: String) -> String {
        let basename = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = basename.lastIndex(of: "."), dot != basename.startIndex else { return "" }
        return basename[basename.index(after: dot)...].lowercased()
    }
}
