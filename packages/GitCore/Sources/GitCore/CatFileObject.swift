import Foundation

/// One git object as returned by `git cat-file --batch`.
///
/// Content is held verbatim as bytes. For text objects (commits, trees,
/// tags) decode via `String(decoding: object.content, as: UTF8.self)`.
/// For blobs the bytes may be arbitrary binary.
public struct CatFileObject: Sendable, Equatable {
    public let sha: String
    public let kind: ObjectKind
    public let content: Data

    public init(sha: String, kind: ObjectKind, content: Data) {
        self.sha = sha
        self.kind = kind
        self.content = content
    }

    /// UTF-8 decoded view of `content`, or nil if invalid UTF-8.
    public var contentString: String? {
        String(data: content, encoding: .utf8)
    }
}

/// Object kinds reported by `git cat-file`.
public enum ObjectKind: String, Sendable, CaseIterable {
    case blob
    case tree
    case commit
    case tag
}
