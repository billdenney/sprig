// PromptLoader — read versioned markdown prompts from disk.
//
// Two seams:
//
// - ``load(named:from:)`` / ``loadAll(from:)`` — directory-based.
//   Tests use temp directories; the user-overridable case (caller
//   has dropped custom prompts in `~/Library/Application Support/
//   Sprig/Prompts/` or similar) calls into here directly.
// - ``load(named:in:)`` / ``loadAll(in:)`` — bundle-based. The
//   default `Bundle.module` resolves AIKit's shipped prompts in
//   `Sources/AIKit/Prompts/*.md`. Lands in commit 2 on this
//   branch alongside the SwiftPM resource wiring.
//
// Lookup is by filename-without-extension. A prompt named
// `commit-message-v1` maps to a file `commit-message-v1.md`.
//
// Tier 1 portable. Pure Foundation. No provider-side concerns.

import Foundation

/// Loader for ``Prompt`` files.
public enum PromptLoader {
    /// File extension prompts are required to use. Pinned to
    /// `"md"` because ADR 0037 specifies markdown specifically
    /// (so prompt diffs render well in GitHub, tooling can syntax-
    /// highlight, etc.).
    public static let fileExtension = "md"

    /// Load one prompt by name from `directory`. Returns the
    /// parsed ``Prompt``; throws ``PromptLoaderError`` for missing
    /// files, unreadable files, or non-UTF-8 content.
    public static func load(named name: String, from directory: URL) throws -> Prompt {
        let url = directory
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension)
        return try load(from: url, name: name)
    }

    /// Load every `.md` file in `directory` as a prompt. Returns
    /// the results sorted by name (deterministic ordering matters
    /// for tests + diff-friendly diagnostic output). Non-`.md`
    /// files are silently skipped; an unreadable `.md` throws.
    public static func loadAll(from directory: URL) throws -> [Prompt] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw PromptLoaderError.directoryUnreadable(
                at: directory,
                underlying: error.localizedDescription
            )
        }
        let markdowns = entries.filter { $0.pathExtension == fileExtension }
        var prompts: [Prompt] = []
        for url in markdowns {
            let name = url.deletingPathExtension().lastPathComponent
            prompts.append(try load(from: url, name: name))
        }
        return prompts.sorted { $0.name < $1.name }
    }

    // MARK: - Internal

    private static func load(from url: URL, name: String) throws -> Prompt {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Distinguish "not found" from "couldn't read" so
            // tests + diagnostics can branch on it.
            if !FileManager.default.fileExists(atPath: url.path) {
                throw PromptLoaderError.notFound(name: name, at: url)
            }
            throw PromptLoaderError.unreadable(
                name: name,
                at: url,
                underlying: error.localizedDescription
            )
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw PromptLoaderError.nonUTF8(name: name, at: url)
        }
        return Prompt(name: name, body: body)
    }
}

/// Failures the loader surfaces. All cases carry the prompt name
/// (where known) for log/diagnostic context.
public enum PromptLoaderError: Error, Equatable, Sendable {
    /// No `<name>.md` in the lookup directory.
    case notFound(name: String, at: URL)

    /// File exists but `Data(contentsOf:)` failed — permission
    /// denied, transient I/O error, etc.
    case unreadable(name: String, at: URL, underlying: String)

    /// Bytes don't decode as UTF-8. Authoring tools that emit
    /// UTF-16 BOM or Latin-1 hit this; the fix is on the prompt
    /// author's side.
    case nonUTF8(name: String, at: URL)

    /// `loadAll` couldn't enumerate the directory.
    case directoryUnreadable(at: URL, underlying: String)
}
