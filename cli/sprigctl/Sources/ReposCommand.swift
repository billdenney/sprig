import ArgumentParser
import Foundation
import GitCore

/// `sprigctl repos [<root>] [--json] [--max-depth N] [--include-hidden] ...`
/// — recursively scan a directory and print every git repo found.
///
/// Wraps ``GitCore/RepoDiscovery``. Useful for "what repos do I have under
/// `~/Projects`?", and is the same scan logic Sprig will use to populate
/// the user's watch-roots list (ADR 0025).
struct ReposCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repos",
        abstract: "Recursively scan a directory and list every git repository found."
    )

    @Argument(help: "Directory to scan (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "Emit one JSON array of paths instead of one path per line.")
    var json: Bool = false

    @Option(name: .long, help: "Maximum directory depth to recurse. Default 8.")
    var maxDepth: Int = 8

    @Flag(name: .long, help: "Descend into hidden (dot-prefixed) directories.")
    var includeHidden: Bool = false

    @Flag(name: .long, help: "Follow symbolic links during scan.")
    var followSymlinks: Bool = false

    @Option(
        name: .customLong("skip"),
        parsing: .upToNextOption,
        help: ArgumentHelp(
            "Directory names to skip (replaces the default skip set). Repeat or pass multiple values: --skip node_modules .build vendor.",
            valueName: "name"
        )
    )
    var skipOverride: [String] = []

    func run() async throws {
        let root = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)

        let options = RepoDiscovery.Options(
            maxDepth: maxDepth,
            followSymlinks: followSymlinks,
            includeHidden: includeHidden,
            skipNames: skipOverride.isEmpty
                ? RepoDiscovery.Options.defaultSkipNames
                : Set(skipOverride)
        )

        let repos = RepoDiscovery.scan(root: root, options: options)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(repos.map(\.path))
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            for repo in repos {
                print(repo.path)
            }
        }
    }
}
