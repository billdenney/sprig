import Foundation

/// Walks a directory tree and reports the path of every git repository it
/// finds.
///
/// A "repository" is any directory that contains a `.git` entry — either a
/// directory (the standard case) or a file (submodules and `git worktree`
/// linked checkouts use a `.git` file pointing at the real gitdir).
///
/// When a repo is found, the walker does NOT descend into it. That's
/// usually what callers want: discovering "which repos live under
/// `~/Projects`" should not enumerate the working trees of those repos.
///
/// The walker is deliberately conservative about pathological scans:
/// - capped at ``Options/maxDepth``,
/// - skips hidden directories by default (those starting with `.`,
///   which also conveniently skips `.git` itself once we've consumed
///   the parent as a repo root),
/// - skips a small built-in list of bulky common directories
///   (`node_modules`, `.build`, etc.) — extensible per call.
///
/// CLAUDE.md: this lives in `GitCore` because it's repo-shaped logic
/// that depends only on Foundation. No platform APIs; portable.
public enum RepoDiscovery {
    /// Knobs for ``scan(root:options:)``.
    public struct Options: Sendable {
        /// How many directory levels deep to recurse before giving up.
        /// `0` means scan only the root itself; `1` means root + immediate
        /// children; etc. Default `8` — deep enough for typical project
        /// layouts (`~/Projects/Acme/repo/...`) and shallow enough to
        /// avoid pathological monorepo descents.
        public var maxDepth: Int

        /// Whether to follow symbolic links. Default `false` — symlink
        /// loops are real and we don't want to chase them.
        public var followSymlinks: Bool

        /// Whether to descend into directories whose name starts with a
        /// `.` (e.g. `.cache`, `.npm`). Default `false`.
        public var includeHidden: Bool

        /// Directory names to skip entirely (literal name match). Default
        /// is the bulk-and-not-interesting set; callers can replace or
        /// extend.
        public var skipNames: Set<String>

        public init(
            maxDepth: Int = 8,
            followSymlinks: Bool = false,
            includeHidden: Bool = false,
            skipNames: Set<String> = Self.defaultSkipNames
        ) {
            self.maxDepth = maxDepth
            self.followSymlinks = followSymlinks
            self.includeHidden = includeHidden
            self.skipNames = skipNames
        }

        /// `node_modules`, `.build`, `.swiftpm`, `target`, `Pods`,
        /// `DerivedData`, `vendor`, `__pycache__`, `dist`. These are
        /// large and never contain user-managed repos (besides their
        /// own `.git` if any, which we'd already enumerate from the
        /// parent project root).
        public static let defaultSkipNames: Set<String> = [
            "node_modules",
            ".build",
            ".swiftpm",
            "target",
            "Pods",
            "DerivedData",
            "vendor",
            "__pycache__",
            "dist"
        ]
    }

    /// Recursively scan `root` and return the paths of every git repo
    /// found, in the order they were encountered (depth-first, sorted
    /// per directory). Paths are the directory CONTAINING `.git`, not
    /// the `.git` entry itself.
    ///
    /// Paths that can't be read (permission errors, broken symlinks,
    /// etc.) are silently skipped — discovery is best-effort.
    public static func scan(root: URL, options: Options = Options()) -> [URL] {
        var found: [URL] = []
        walk(at: root, depth: 0, options: options, into: &found)
        return found
    }

    private static func walk(
        at url: URL,
        depth: Int,
        options: Options,
        into found: inout [URL]
    ) {
        // Quick check: is this directory itself a git repo?
        if hasGitMarker(at: url) {
            found.append(url.standardizedFileURL)
            return
        }

        guard depth < options.maxDepth else { return }

        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants]
            )
        } catch {
            return
        }

        // Sort for deterministic output across platforms / runs.
        let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in sorted {
            let name = child.lastPathComponent

            if options.skipNames.contains(name) { continue }
            if !options.includeHidden, name.hasPrefix(".") { continue }

            let values = try? child.resourceValues(forKeys: Set(resourceKeys))
            let isDir = values?.isDirectory ?? false
            let isSymlink = values?.isSymbolicLink ?? false
            guard isDir else { continue }
            if isSymlink, !options.followSymlinks { continue }

            walk(at: child, depth: depth + 1, options: options, into: &found)
        }
    }

    /// Returns true if `dir/.git` exists, regardless of whether the
    /// `.git` is a directory (normal repo) or a file (submodule, linked
    /// worktree).
    private static func hasGitMarker(at dir: URL) -> Bool {
        let dotGit = dir.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit.path)
    }
}
