import Foundation

/// Parser for `git log` output produced with ``LogParser/formatString`` and
/// `-z` (NUL-terminated entries).
///
/// We use ASCII Unit Separator (`U+001F`) between fields and let `-z`
/// terminate each entry. This keeps the parse byte-stable: `%H` (40-char
/// hex), `%P` (space-separated SHAs), `%aI` / `%cI` (ISO-8601), name and
/// email trailers, subject, and body never legitimately contain U+001F
/// or NUL.
///
/// To invoke the matching git command:
///
/// ```
/// git log -z --format=<LogParser.formatString> [<more args>]
/// ```
public enum LogParser {
    /// `git log` format string that matches what ``parse(_:)`` expects.
    /// Field order: SHA, parents, author-date, committer-date,
    /// author-name, author-email, committer-name, committer-email,
    /// subject, body.
    public static let formatString =
        "%H%x1f%P%x1f%aI%x1f%cI%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%B"

    /// Parse the raw bytes of `git log -z --format=<formatString>` into
    /// an ordered array of commits.
    public static func parse(_ data: Data) throws -> [Commit] {
        var commits: [Commit] = []
        var index = data.startIndex
        let nul: UInt8 = 0x00

        while index < data.endIndex {
            // Find the NUL that terminates this entry.
            let entryEnd = data[index...].firstIndex(of: nul) ?? data.endIndex
            let slice = data[index ..< entryEnd]
            if !slice.isEmpty {
                try commits.append(parseEntry(Data(slice)))
            }
            index = entryEnd < data.endIndex ? data.index(after: entryEnd) : data.endIndex
        }
        return commits
    }

    private static func parseEntry(_ entry: Data) throws -> Commit {
        let trimmed = trimLeadingNewlines(entry)
        let fields = splitOnUnitSeparator(trimmed)
        guard fields.count == 10 else {
            let snippet = String(data: trimmed.prefix(80), encoding: .utf8) ?? "<non-UTF-8>"
            throw GitError.parseFailure(
                context: "log entry expected 10 fields separated by U+001F, got \(fields.count)",
                rawSnippet: snippet
            )
        }
        let parentsField = decodeUTF8(fields[1])
        let parents = parentsField.isEmpty
            ? []
            : parentsField.split(separator: " ").map(String.init)
        let bodyRaw = decodeUTF8(fields[9])
        return try Commit(
            sha: decodeUTF8(fields[0]),
            parents: parents,
            author: Identity(name: decodeUTF8(fields[4]), email: decodeUTF8(fields[5])),
            committer: Identity(name: decodeUTF8(fields[6]), email: decodeUTF8(fields[7])),
            authorDate: requiredISO(decodeUTF8(fields[2]), context: "author date"),
            committerDate: requiredISO(decodeUTF8(fields[3]), context: "committer date"),
            subject: decodeUTF8(fields[8]),
            // %B includes a trailing newline; strip for tidier display.
            body: bodyRaw.hasSuffix("\n") ? String(bodyRaw.dropLast()) : bodyRaw
        )
    }

    private static func splitOnUnitSeparator(_ data: Data) -> [Data] {
        let unitSeparator: UInt8 = 0x1F
        var fields: [Data] = []
        var current = Data()
        for byte in data {
            if byte == unitSeparator {
                fields.append(current)
                current = Data()
            } else {
                current.append(byte)
            }
        }
        fields.append(current)
        return fields
    }

    private static func requiredISO(_ string: String, context: String) throws -> Date {
        guard let date = parseISO8601(string) else {
            throw GitError.parseFailure(
                context: "log entry: bad \(context)",
                rawSnippet: string
            )
        }
        return date
    }

    private static func trimLeadingNewlines(_ data: Data) -> Data {
        var i = data.startIndex
        while i < data.endIndex, data[i] == 0x0A {
            i = data.index(after: i)
        }
        return Data(data[i...])
    }

    private static func decodeUTF8(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<non-UTF-8>"
    }

    /// Parse an ISO-8601 date as emitted by `%aI` / `%cI`. Uses
    /// `Date.ISO8601FormatStyle` (Sendable) rather than the older
    /// `ISO8601DateFormatter` (not Sendable in Swift 6).
    private static func parseISO8601(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}
