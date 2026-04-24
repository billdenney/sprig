import Foundation

/// Parsed `git --version` output.
///
/// Sprig's minimum supported git is 2.39 (Apple-bundled on macOS 14). Newer
/// capabilities are feature-detected at runtime against this type (see §11.2
/// of the plan for the Scalar-stack tiering).
public struct GitVersion: Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Vendor-specific suffix (e.g. "(Apple Git-146)" on macOS). May be empty.
    public let suffix: String

    public init(major: Int, minor: Int, patch: Int, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    public static let minimumSupported = GitVersion(major: 2, minor: 39, patch: 0)

    /// Parses `git version 2.43.0` or `git version 2.39.5 (Apple Git-154)`.
    public static func parse(_ raw: String) -> GitVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "git version "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)

        // Split on first whitespace to separate version from vendor suffix.
        let firstSpace = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        let versionPart = rest[..<firstSpace]
        let suffixPart = rest[firstSpace...].trimmingCharacters(in: .whitespaces)

        let components = versionPart.split(separator: ".")
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1])
        else { return nil }
        let patch = components.count >= 3 ? (Int(components[2]) ?? 0) : 0
        return GitVersion(major: major, minor: minor, patch: patch, suffix: String(suffixPart))
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return suffix.isEmpty ? core : "\(core) \(suffix)"
    }

    /// Strict lexicographic comparison on (major, minor, patch). Suffix ignored.
    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var meetsMinimum: Bool {
        !(self < Self.minimumSupported)
    }
}

extension GitVersion: Comparable {}
