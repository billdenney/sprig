// ContentType.swift
//
// ADR 0086 C0 — content-type detection from a blob's leading bytes, the
// "sniff" leg of diff classification (the other legs are the numstat
// binary marker and `.gitattributes` `diff=`/`merge=` drivers). Used to
// route a changed file to the right renderer (image / PDF / Office /
// text / …) when neither git's binary marker nor a configured driver
// already decides it.
//
// Magic-number based, deterministic, no external dependencies. We sniff
// only what we can route confidently; everything else is `.plainText`
// (no NUL in the header) or `.unknownBinary`.
//
// Tier 1, portable. Pure value logic — no git, no I/O.

import Foundation

/// A coarse content type inferred from a blob's leading bytes.
public enum ContentType: String, Sendable, Equatable, CaseIterable {
    case png
    case jpeg
    case gif
    case webp
    case pdf
    /// A ZIP container — the on-disk shape of Office documents
    /// (`.docx`/`.xlsx`/`.pptx`) and many other formats.
    case zipContainer
    /// Looks like text (UTF-8/ASCII, no NUL in the sniffed window).
    case plainText
    /// Binary, but not a type we recognize.
    case unknownBinary

    /// True for types that are inherently binary (not `.plainText`).
    public var isBinary: Bool {
        self != .plainText
    }
}

/// Magic-number content sniffing over a blob's leading bytes.
public enum ContentTypeSniffer {
    /// How many leading bytes are enough to classify (and to decide
    /// text-vs-binary by scanning for a NUL).
    public static let sniffByteCount = 8000

    /// Classify `data` (typically just the file's first few KiB) by its
    /// magic number, falling back to a NUL-byte text/binary heuristic —
    /// the same rule git uses to decide "binary".
    public static func sniff(_ data: Data) -> ContentType {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if isWebP(data) { return .webp }
        if data.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return .zipContainer
        }
        // No magic match: text iff there's no NUL in the sniffed window
        // (git's own binary heuristic).
        return data.prefix(sniffByteCount).contains(0) ? .unknownBinary : .plainText
    }

    /// `RIFF????WEBP` — a RIFF container whose form type is `WEBP`.
    private static func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = Array(data.prefix(12))
        return Array(bytes[0 ..< 4]) == Array("RIFF".utf8)
            && Array(bytes[8 ..< 12]) == Array("WEBP".utf8)
    }
}
