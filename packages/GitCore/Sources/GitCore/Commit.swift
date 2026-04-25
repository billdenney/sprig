import Foundation

/// A single git commit, as returned by ``LogParser``.
public struct Commit: Sendable, Equatable {
    /// 40-character object SHA-1 (or 64-char SHA-256 in newer repos).
    public let sha: String
    /// Parent SHAs. Empty for root commits, single for normal commits,
    /// two-or-more for merges.
    public let parents: [String]
    /// Person who authored the change (may differ from committer in
    /// rebased / cherry-picked / signed-off histories).
    public let author: Identity
    /// Person who committed the change.
    public let committer: Identity
    /// ISO-8601 author date.
    public let authorDate: Date
    /// ISO-8601 committer date.
    public let committerDate: Date
    /// First line of the commit message (subject).
    public let subject: String
    /// Full commit message body, including the subject line.
    public let body: String

    public init(
        sha: String,
        parents: [String],
        author: Identity,
        committer: Identity,
        authorDate: Date,
        committerDate: Date,
        subject: String,
        body: String
    ) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.committer = committer
        self.authorDate = authorDate
        self.committerDate = committerDate
        self.subject = subject
        self.body = body
    }

    /// Convenience: short SHA (first 7 chars) — what most tools display
    /// inline.
    public var shortSHA: String {
        String(sha.prefix(7))
    }

    /// True when this commit has more than one parent (a merge).
    public var isMerge: Bool {
        parents.count > 1
    }
}

/// An author or committer identity — the `Name <email>` portion of a
/// trailer plus the date.
public struct Identity: Sendable, Equatable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}
