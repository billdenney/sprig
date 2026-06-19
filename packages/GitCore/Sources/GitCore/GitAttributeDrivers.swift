// GitAttributeDrivers.swift
//
// ADR 0086 C0 — read the `.gitattributes` `diff=` and `merge=` driver
// names for a batch of paths via `git check-attr`, the defer-to-git leg
// of diff classification (ADR 0023). When a path declares
// `*.png diff=exif merge=binary`, the user has told git how to handle
// it; Sprig honors that — routing to the configured driver / external
// tool — before falling back to built-in renderers.
//
// Mirrors `LFSKit.LFSAttributeChecker` (which queries only `filter`),
// but lives in GitCore so any tier can read driver attributes.
//
// Tier 1, portable. All git access via ``Runner``.

import Foundation

/// The configured `diff=`/`merge=` drivers for one path (nil when the
/// attribute is unspecified or a bare boolean rather than a named
/// driver).
public struct AttributeDrivers: Sendable, Equatable {
    public let path: String
    public let diff: String?
    public let merge: String?

    public init(path: String, diff: String?, merge: String?) {
        self.path = path
        self.diff = diff
        self.merge = merge
    }
}

/// `git check-attr -z --stdin diff merge` runner + parser.
public enum GitAttributeDrivers {
    /// Query the `diff` and `merge` driver attributes for `paths`.
    /// Returns one result per path, input order preserved.
    public static func query(paths: [String], runner: Runner) async throws -> [AttributeDrivers] {
        guard !paths.isEmpty else { return [] }
        var stdin = Data()
        for path in paths {
            stdin.append(contentsOf: path.utf8)
            stdin.append(0)
        }
        let output = try await runner.run(
            ["check-attr", "-z", "--stdin", "diff", "merge"],
            stdin: stdin
        )
        return parse(output.stdout, order: paths)
    }

    /// Parse the NUL-separated `<path>\0<attr>\0<value>\0` triples into
    /// one ``AttributeDrivers`` per path, preserving `order`.
    static func parse(_ data: Data, order: [String]) -> [AttributeDrivers] {
        // swiftlint:disable:next optional_data_string_conversion
        let tokens = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0}")
        var diffByPath: [String: String] = [:]
        var mergeByPath: [String: String] = [:]
        var index = 0
        while index + 2 < tokens.count {
            let path = tokens[index]
            let attribute = tokens[index + 1]
            let value = tokens[index + 2]
            index += 3
            guard let driver = driverName(from: value) else { continue }
            if attribute == "diff" { diffByPath[path] = driver }
            if attribute == "merge" { mergeByPath[path] = driver }
        }
        return order.map { AttributeDrivers(path: $0, diff: diffByPath[$0], merge: mergeByPath[$0]) }
    }

    /// A named driver, or nil for git's non-driver states
    /// (`unspecified`, `unset`, and the bare-boolean `set`).
    private static func driverName(from value: String) -> String? {
        switch value {
        case "unspecified", "unset", "set": nil
        default: value
        }
    }
}
