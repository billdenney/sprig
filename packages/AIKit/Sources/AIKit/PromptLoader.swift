// PromptLoader — read versioned markdown prompts from disk.
//
// Two seams:
//
// - ``loadBundled(named:)`` / ``loadAllBundled()`` — resolves
//   AIKit's shipped prompts (`Sources/AIKit/Prompts/*.md` declared
//   as `.process`'d resources in `Package.swift`) via the
//   SwiftPM-generated `Bundle.module`. `Bundle.module` is internal,
//   which is why the bundle isn't a parameter on the public API.
// - ``load(named:from:)`` / ``loadAll(from:)`` — directory-based.
//   Tests use temp directories; the user-overridable case (caller
//   has dropped custom prompts in `~/Library/Application Support/
//   Sprig/Prompts/` or similar) calls into here directly.
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

    /// Load one of AIKit's shipped prompts by name. Resolves from
    /// `Bundle.module` — the `Sources/AIKit/Prompts/*.md` files
    /// declared as `.process`'d resources in `Package.swift`.
    ///
    /// `Bundle.module` is internal to AIKit (SwiftPM-generated), so
    /// it can't appear in the public signature; callers that want
    /// user-overridable prompts should use ``load(named:from:)``
    /// with an explicit directory URL.
    public static func loadBundled(named name: String) throws -> Prompt {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension
        ) else {
            throw PromptLoaderError.notFound(
                name: name,
                at: Bundle.module.bundleURL
            )
        }
        return try load(from: url, name: name)
    }

    /// Load every prompt shipped in AIKit. Returns sorted by name.
    ///
    /// Uses `bundle.urls(forResourcesWithExtension:subdirectory:)`
    /// — SwiftPM's `.process` resource declaration flattens the
    /// `Prompts/` subdir into the bundle root, so the subdirectory
    /// argument is nil rather than `"Prompts"`. The Linux
    /// (swift-corelibs-foundation) signature returns `[NSURL]?`
    /// rather than the `[URL]?` on Apple platforms, hence the
    /// `.map { $0 as URL }` bridge.
    public static func loadAllBundled() throws -> [Prompt] {
        let nsurls = Bundle.module.urls(
            forResourcesWithExtension: fileExtension,
            subdirectory: nil
        ) ?? []
        let urls = nsurls.map { $0 as URL }
        var prompts: [Prompt] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            try prompts.append(load(from: url, name: name))
        }
        return prompts.sorted { $0.name < $1.name }
    }

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
            try prompts.append(load(from: url, name: name))
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
