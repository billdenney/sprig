// ConflictedFile.swift
//
// Pairs a file's source text with the conflict regions inside it, so
// the splice-back step can replace each region's marker block with a
// user-chosen `ConflictResolution`. Slice C2 of the M4
// (MergeConflictResolver) track.
//
// Tier 1 portable. No platform APIs, no I/O — purely transforms
// strings.

import Foundation

/// A file that contains zero or more conflict regions, plus the
/// machinery to splice in chosen resolutions.
///
/// **Construction.** The convenience initializer ``init(source:)``
/// runs the parser; ``init(source:regions:)`` is a direct constructor
/// for callers that already parsed (e.g. parsed once, applied
/// resolutions repeatedly during user editing).
///
/// **Output line endings.** The parser's `enumerateLines` and
/// ``applying(_:)``'s `joined(separator:)` together produce LF-only
/// output regardless of the source's line endings. Callers that need
/// CRLF on Windows or other input-line-ending preservation should
/// post-process; the M4 merge surface stores files via `String.write`
/// which handles platform conventions itself.
public struct ConflictedFile: Equatable, Sendable {
    /// The original file contents.
    public let source: String

    /// Conflict regions parsed from ``source`` — same array
    /// ``ConflictParser/parse(_:)`` returns.
    public let regions: [ConflictRegion]

    /// Construct by parsing `source`. Equivalent to
    /// `ConflictedFile(source: source, regions: ConflictParser.parse(source))`.
    public init(source: String) {
        self.source = source
        self.regions = ConflictParser.parse(source)
    }

    /// Construct from an already-parsed pair. Useful when the caller
    /// has cached parser output across multiple resolution attempts.
    /// No invariant-checking is done — the regions are trusted to
    /// describe `source`.
    public init(source: String, regions: [ConflictRegion]) {
        self.source = source
        self.regions = regions
    }

    /// True when ``regions`` is empty — the file is clean.
    public var isClean: Bool {
        regions.isEmpty
    }

    /// Produce the resolved file contents by replacing each region's
    /// marker block with the corresponding entry in `resolutions`.
    ///
    /// The arrays index in lockstep: `resolutions[i]` is applied to
    /// `regions[i]`. ``ConflictResolutionError/resolutionCountMismatch(expected:got:)``
    /// is thrown if the counts disagree;
    /// ``ConflictResolutionError/baseRequestedButMissing(regionIndex:)``
    /// is thrown when `.base` is requested for a non-diff3 region.
    ///
    /// Lines outside any region are preserved verbatim; lines inside
    /// a region are dropped and replaced with the resolution's lines
    /// (or kept verbatim for ``ConflictResolution/unresolved``). The
    /// trailing newline of the source is preserved if present.
    public func applying(_ resolutions: [ConflictResolution]) throws -> String {
        guard resolutions.count == regions.count else {
            throw ConflictResolutionError.resolutionCountMismatch(
                expected: regions.count,
                got: resolutions.count
            )
        }

        // Split into LF-relative lines (CRLF-safe via enumerateLines).
        var lines: [String] = []
        source.enumerateLines { line, _ in lines.append(line) }

        // Walk lines 1-indexed; whenever we hit a region's start
        // line, splice in its resolution and skip past the region.
        // `regions` is the parser's output, which is already in
        // ascending lineRange order; assert that and rely on it.
        let sortedRegions = regions
        var resultLines: [String] = []
        resultLines.reserveCapacity(lines.count)

        var lineIndex = 0 // 0-based into `lines`
        var regionIndex = 0
        while lineIndex < lines.count {
            let lineNumber = lineIndex + 1 // 1-indexed
            let isRegionStart = regionIndex < sortedRegions.count
                && lineNumber == sortedRegions[regionIndex].lineRange.lowerBound
            guard isRegionStart else {
                resultLines.append(lines[lineIndex])
                lineIndex += 1
                continue
            }
            let region = sortedRegions[regionIndex]
            let resolution = resolutions[regionIndex]
            try splice(
                region: region,
                resolution: resolution,
                regionIndex: regionIndex,
                sourceLines: lines,
                into: &resultLines
            )
            // Advance past the region's last line. lineRange is
            // 1-indexed inclusive; upperBound (1-indexed) is the
            // 0-indexed line *after* the region.
            lineIndex = region.lineRange.upperBound
            regionIndex += 1
        }

        var output = resultLines.joined(separator: "\n")
        if source.hasSuffix("\n") {
            output += "\n"
        }
        return output
    }

    /// Append the chosen resolution's lines to `result`. Factored out
    /// to keep ``applying(_:)`` under SwiftLint's body-length cap as
    /// the splice surface grows.
    private func splice(
        region: ConflictRegion,
        resolution: ConflictResolution,
        regionIndex: Int,
        sourceLines: [String],
        into result: inout [String]
    ) throws {
        switch resolution {
        case .ours:
            result.append(contentsOf: region.ours)
        case .theirs:
            result.append(contentsOf: region.theirs)
        case .base:
            guard let base = region.base else {
                throw ConflictResolutionError.baseRequestedButMissing(regionIndex: regionIndex)
            }
            result.append(contentsOf: base)
        case let .custom(customLines):
            result.append(contentsOf: customLines)
        case .unresolved:
            // Re-emit the region's lines verbatim, including the
            // marker lines, by reading them out of `sourceLines`.
            // lineRange is 1-indexed inclusive; convert to 0-indexed.
            let start = region.lineRange.lowerBound - 1
            let endInclusive = region.lineRange.upperBound - 1
            for i in start ... endInclusive {
                result.append(sourceLines[i])
            }
        }
    }
}
