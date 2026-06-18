// LFSBinaryTypes.swift
//
// ADR 0091 — the curated set of file types that belong in Git LFS
// regardless of size. The size rail (`largeStagedFileWithoutLFS`,
// ADR 0070) catches big files; this set catches the small-to-medium
// binaries (`.psd`, `.docx`, short `.mp4`, …) that bloat history and
// merge badly but slip under the size threshold.
//
// Tier 1, portable. Pure Foundation; matching is by extension, the way
// a `*.ext` `.gitattributes` pattern works. Injectable (the default set
// is a maintenance item, audited periodically like the junk-file
// defaults) so callers and tests can substitute their own.

import Foundation

/// A curated set of binary file extensions that warrant LFS tracking.
public struct LFSBinaryTypes: Sendable, Equatable {
    /// Lowercased extensions without the leading dot (e.g. `psd`).
    public let extensions: Set<String>

    public init(extensions: Set<String> = LFSBinaryTypes.defaultExtensions) {
        self.extensions = extensions
    }

    /// The default curated set (ADR 0091). Grouped by why they hurt in
    /// git: design/art assets, archives/images, audio/video, Office
    /// documents, and disk/binary blobs.
    public static let defaultExtensions: Set<String> = [
        // Design / art assets (large, opaque, frequently re-saved).
        "psd", "ai", "sketch", "fig", "xcf", "indd",
        // Archives + disk images.
        "zip", "7z", "rar", "gz", "tar", "iso", "dmg", "pkg",
        // Audio / video.
        "mp4", "mov", "avi", "mkv", "webm", "wav", "flac", "aiff", "mp3",
        // Office documents (zip-container binaries; terrible diffs/merges).
        "docx", "xlsx", "pptx", "doc", "xls", "ppt", "pdf",
        // Misc binary blobs.
        "bin", "exe", "dll", "so", "dylib", "a", "o"
    ]

    /// True if `path`'s extension is in the curated set (case-insensitive,
    /// like Windows/macOS default filesystems).
    public func matches(path: String) -> Bool {
        guard let ext = Self.fileExtension(of: path) else { return false }
        return extensions.contains(ext)
    }

    /// The `.gitattributes`-style LFS pattern for `path`'s type (e.g.
    /// `*.psd`), or nil when the path has no matching extension.
    public func suggestedPattern(for path: String) -> String? {
        guard let ext = Self.fileExtension(of: path), extensions.contains(ext) else { return nil }
        return "*.\(ext)"
    }

    /// The lowercased extension of a path's last component, without the
    /// dot. Nil for dotfiles (`.env`) and extension-less names — git
    /// emits forward slashes on every platform, so we split on `/`.
    static func fileExtension(of path: String) -> String? {
        let basename = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = basename.lastIndex(of: "."), dot != basename.startIndex else { return nil }
        let ext = basename[basename.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }
}
