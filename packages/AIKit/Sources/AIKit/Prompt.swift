// Prompt — a versioned, in-repo markdown prompt loaded by AIKit.
//
// Per ADR 0037: prompts live as `.md` files under
// `packages/AIKit/Sources/AIKit/Prompts/`. Bundling them as
// SwiftPM resources gives ``PromptLoader`` runtime access via
// `Bundle.module`; reading them from a caller-supplied directory
// (the user-overridable case) goes through the same loader.
//
// Tier 1 portable. Pure Foundation. No provider-side concerns.

import Foundation

/// A single prompt — the canonical input to ``AIProvider/complete(request:)``.
///
/// First-slice shape: just name + body. The name is the filename
/// without the `.md` extension; the body is the file contents
/// verbatim. Templating (variable substitution, frontmatter,
/// versioning hints) is a future addition — keeping this minimal
/// avoids welding the loader to one templating choice before we
/// know which Sprig callers (CommitComposer, MergeConflictResolver,
/// PR-description drafter) want.
public struct Prompt: Sendable, Equatable {
    /// Filename without the `.md` extension. Used as the lookup key
    /// in ``PromptLoader/load(named:in:)``.
    public let name: String

    /// Raw file contents, decoded as UTF-8. Trailing whitespace /
    /// final newline are preserved — caller decides whether to trim
    /// before sending to a provider (Sprig prompts are typically
    /// authored with a final newline that's fine to keep).
    public let body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }
}
