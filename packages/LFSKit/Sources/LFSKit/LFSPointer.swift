// LFSPointer.swift
//
// Parser for git-lfs pointer files. A pointer file is what lives in
// the user's working tree when `git-lfs` is configured but the actual
// large object hasn't been smudged yet. Format (per
// https://github.com/git-lfs/git-lfs/blob/main/docs/spec.md):
//
//     version https://git-lfs.github.com/spec/v1
//     oid sha256:<64 lowercase hex chars>
//     size <decimal bytes>
//
// LF terminator on every line including the last; total payload
// bounded to a few hundred bytes (one Git "small object" blob worth).
//
// Sprig uses this for the `.lfsPointer` badge (ADR 0019) — a tracked
// file that *looks* clean but is actually a stub. The badge surfaces
// "you don't have the real bytes locally" so the user notices before
// hitting a confusing tool error downstream.
//
// Tier 1, Foundation-only. Pure value-type code; no git invocation,
// no I/O.

import Foundation

/// A parsed git-lfs pointer file.
///
/// **Wire-stable.** The three required fields (`version`, `oid`,
/// `size`) are exactly what's in the file; we don't synthesize or
/// derive any. Consumers can show the OID prefix in the merge UI to
/// confirm a pointer matches what they expect.
public struct LFSPointer: Equatable, Hashable, Sendable {
    /// First-line value, e.g. `https://git-lfs.github.com/spec/v1`.
    /// Carried through verbatim so callers that need to distinguish
    /// future spec versions can.
    public let version: String

    /// SHA-256 hash of the underlying object's content. 64 lowercase
    /// hex characters; stored without the `sha256:` prefix (the only
    /// algorithm git-lfs supports today, so the prefix is redundant
    /// for callers but kept on the wire for forward compat).
    public let oidSHA256: String

    /// Size in bytes of the underlying object. The pointer file
    /// itself is much smaller; this is what `git lfs pull` would
    /// download.
    public let size: Int

    public init(version: String, oidSHA256: String, size: Int) {
        self.version = version
        self.oidSHA256 = oidSHA256
        self.size = size
    }
}

/// Parser + cheap "could this be an LFS pointer?" probe. Stateless.
public enum LFSPointerParser {
    /// Maximum reasonable size for a pointer file. Real pointers are
    /// well under 200 bytes; budget 4 KiB so we never accidentally
    /// try to parse a multi-megabyte text file as a pointer.
    public static let maxPointerByteCount = 4096

    /// Cheap discriminator: returns true iff `data` *might* be an
    /// LFS pointer. Used as a gate before the full parse so callers
    /// reading thousands of files in a directory walk don't pay the
    /// parsing cost on every regular text file.
    ///
    /// The check is byte-level (no decoding) so it works on file
    /// streams that haven't been read fully yet — a few hundred
    /// bytes is enough.
    public static func isLikelyPointer(_ data: Data) -> Bool {
        guard data.count <= maxPointerByteCount else { return false }
        // Must start with literal `version https://git-lfs.github.com/spec/`.
        // Older git-lfs versions wrote `https://hawser.github.com/spec/v1`;
        // we don't accept that — anything that ancient is a museum
        // piece.
        let prefix = Data("version https://git-lfs.github.com/spec/".utf8)
        guard data.starts(with: prefix) else { return false }
        return true
    }

    /// Parse `source` (the file's text contents) as an LFS pointer.
    /// Returns nil for any input that doesn't strictly match the
    /// spec — missing fields, wrong order, malformed OID,
    /// non-numeric size, extra trailing content, etc. Strict because
    /// a "loose" parse would shadow real text files that happen to
    /// have a `version` line.
    public static func parse(_ source: String) -> LFSPointer? {
        // Spec calls for exactly three lines, each LF-terminated, in
        // this order: version, oid, size. We tolerate CRLF on the
        // way in via `enumerateLines` (CRLF-safe per the project's
        // IO conventions), then re-validate the strict shape.
        var lines: [String] = []
        source.enumerateLines { line, _ in lines.append(line) }
        guard lines.count == 3 else { return nil }

        guard let version = parseVersionLine(lines[0]) else { return nil }
        guard let oid = parseOIDLine(lines[1]) else { return nil }
        guard let size = parseSizeLine(lines[2]) else { return nil }

        return LFSPointer(version: version, oidSHA256: oid, size: size)
    }

    // MARK: - Per-line parsers (exposed for tests)

    /// `version <url>`. Returns the URL or nil.
    static func parseVersionLine(_ line: String) -> String? {
        let prefix = "version "
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count))
        guard !value.isEmpty else { return nil }
        // Pin to the canonical git-lfs spec URL (current and only
        // form in the wild). Reject pre-1.0 hawser-era URLs.
        guard value.hasPrefix("https://git-lfs.github.com/spec/") else { return nil }
        return value
    }

    /// `oid sha256:<64 hex>`. Returns the bare 64-hex string (no
    /// `sha256:` prefix), or nil.
    static func parseOIDLine(_ line: String) -> String? {
        let prefix = "oid sha256:"
        guard line.hasPrefix(prefix) else { return nil }
        let hex = String(line.dropFirst(prefix.count))
        guard hex.count == 64 else { return nil }
        guard hex.allSatisfy(\.isLowercaseHex) else { return nil }
        return hex
    }

    /// `size <decimal>`. Returns the integer bytes, or nil.
    static func parseSizeLine(_ line: String) -> Int? {
        let prefix = "size "
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count))
        // Strict: only ASCII digits, no leading + / -, no underscores.
        guard !value.isEmpty, value.allSatisfy(\.isAsciiDigit) else { return nil }
        return Int(value)
    }
}

private extension Character {
    /// True for `0-9` and `a-f` ASCII (no uppercase — git-lfs
    /// always lowercases, and accepting both would shadow valid
    /// pointer-file content from other tooling).
    var isLowercaseHex: Bool {
        guard isASCII else { return false }
        return ("0" ... "9").contains(self) || ("a" ... "f").contains(self)
    }

    var isAsciiDigit: Bool {
        guard isASCII else { return false }
        return ("0" ... "9").contains(self)
    }
}
