# Git Backend

How Sprig invokes the user's `git` binary, parses the output, and caches what it can. All git access goes through `packages/GitCore/` — no other package or app target is allowed to spawn git directly.

ADR cross-references: 0001 (use system git), 0023 (no libgit2), 0026 (Scalar-style defaults), 0047 (git detection), 0049 (modern config defaults), 0052 (force-with-lease).

## Why shell out instead of libgit2

We deliberately do not embed `libgit2` (ADR 0023). Reasons:

- **LFS, hooks, filter drivers, credentials, signing, aliases, includes** — all of these are part of "what the user expects from `git`," and they're built into the user's installed git. libgit2's coverage of these features lags upstream and is incomplete in important corners (LFS smudge/clean, modern signing, partial clone server protocol).
- **Cross-platform consistency.** Git for Windows, macOS Apple-bundled git, and Linux distro git all behave identically modulo version. libgit2 wraps a Swift facade around behavior that already varies by platform; shelling out gets us "whatever the user's git does."
- **Debuggability.** A user reports "Sprig hangs on push." With shelling-out, the maintainer sees the exact command and can re-run it in a terminal. With libgit2, reproducing the bug requires standing up the same library version and walking the user through API state.
- **Lower binary size.** No libgit2 means no dependency tree under it (libssh2, mbedTLS, zlib).

The cost is per-call fork/exec overhead. We mitigate it three ways:

1. **`CatFileBatch`** — long-lived `git cat-file --batch` per repo. One fork at startup, then reads are pipe round-trips. Used wherever we do many object reads (diff, blame, log walking, future history viewer).
2. **`core.fsmonitor`** — Sprig becomes the fsmonitor source for repos it watches (ADR 0024). `git status` then asks Sprig "what changed since token X?" and gets back O(changed paths) instead of walking the full tree. Implementation lands during M2/M3.
3. **`--porcelain=v2 -z` parsing** — single git invocation produces the full status; one parser walks NUL-delimited records.

## `GitCore.Runner`

The one-shot git invoker. Async; spawns one git process per call.

Responsibilities:

- **Argv handling.** Arguments are passed as `[String]` directly to `Foundation.Process` — never assembled into a shell string, so quoting is never an issue.
- **Working directory.** Either explicit per-call (`cwd: URL`) or the runner's default. Always set, never inherits from the spawning process.
- **Environment scrubbing.** Removes `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG`, `GIT_CONFIG_GLOBAL` so they can't leak from a parent shell. Sets `GIT_TERMINAL_PROMPT=0` (no tty prompts; credentials flow through `CredentialKit` later). Sets `LC_ALL=C.UTF-8` and `LANG=C.UTF-8` so `--porcelain=v2` byte output is locale-stable.
- **PATH lookup.** Case-insensitive (Windows env vars are case-insensitive at the OS level but Swift's `ProcessInfo.environment` dictionary isn't). Resolves `git` on POSIX, `git.exe` on Windows. If git isn't on PATH, throws `GitError.binaryNotFound(probedPath:)` rather than letting `Process` throw a generic ENOENT.
- **Stdin / stdout / stderr.** All three captured; stdin can be fed bytes if needed; output returned as `Data` (caller decides decoding).
- **Exit handling.** Non-zero exits throw `GitError.nonZeroExit(command:exitCode:stderr:stdout:)` by default. Pass `throwOnNonZero: false` to inspect failure output without an exception (e.g. `git status` returns 0 even on a non-repo, but `git merge` returns non-zero on conflicts and that's expected).

Concurrent invocations are fine — each is its own process. The `CommandRouter` (in the agent) serializes mutating ops per repo at a higher level.

## `GitCore.CatFileBatch`

Long-lived `git cat-file --batch` actor.

Wire protocol (per `git-cat-file(1)` "BATCH OUTPUT"):

```
> <object-name>\n
< <sha> <type> <size>\n<content bytes>\n
```

or for missing objects:

```
> <object-name>\n
< <object-name> missing\n
```

Implementation:

- Spawn process with stdin/stdout pipes; stash continuations in actor-isolated state so concurrent `read(_:)` calls serialize correctly.
- For each `read(name)`: write `\(name)\n`, read header line, parse `<sha> <type> <size>` or `<name> missing`.
- For success, read exactly `size` bytes (loop over partial reads — pipes return short on Linux/Windows often), then read the trailing `\n`.
- Throw `GitError.objectNotFound(name)` on missing.
- `close()` writes EOF to stdin, awaits child exit, marks the actor closed; subsequent `read` throws `GitError.closed("CatFileBatch")`. Idempotent.

`deinit` terminates a still-running child as a safety net.

When to use vs `Runner`:

- **Use `Runner`** for one-shot commands or anything that mutates the repo (commit, push, merge, etc.).
- **Use `CatFileBatch`** for many small read-only object lookups in a tight loop. Examples: rendering a 50-commit log graph (read each commit's tree → read each tree's blobs to compute diffs), blame view (read the blob at every revision touching a file), conflict resolver (read base/ours/theirs blobs).

## Output parsers

### `PorcelainV2Parser`

Format reference: `git-status(1)` "Porcelain Format Version 2."

We always invoke with `git status --porcelain=v2 -z [--branch] [--show-stash] [--untracked-files=all]`. The `-z` switch terminates each entry with NUL and disables path quoting — paths come through as raw bytes.

Supported entry kinds:

- **Header lines** (`# branch.oid <commit>`, `# branch.head <branch>`, `# branch.upstream <ref>`, `# branch.ab +<n> -<m>`, `# stash <count>`).
- **Ordinary changed files** (line prefix `1 `): X+Y status codes, submodule state, file modes (HEAD/index/worktree), object hashes, path.
- **Renamed/copied** (`2 `): same as ordinary plus an `R<score>` or `C<score>` op marker; the new path is on the entry line, the original path is the *next* NUL-terminated record (so type-2 entries consume two records).
- **Unmerged** (`u `): two-character XY plus three stage hashes (base/ours/theirs).
- **Untracked** (`? <path>`).
- **Ignored** (`! <path>`).

Forward compatibility: unknown `# branch.*` headers are tolerated (silently ignored). Unknown entry prefixes throw `GitError.parseFailure`.

### `LogParser`

Invoke as `git log -z --format=<LogParser.formatString> [-n N] [<rev-range>]` where `formatString` is:

```
%H%x1f%P%x1f%aI%x1f%cI%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%B
```

Fields are separated by ASCII Unit Separator (`U+001F`); entries are NUL-terminated by `-z`. The chosen separators avoid false positives because:

- `%H` / `%P` are hex SHAs.
- `%aI` / `%cI` are ISO-8601 timestamps.
- Names, emails, and subjects are short text where U+001F is essentially never typed.
- Bodies (`%B`) can contain arbitrary text but virtually never contain U+001F or NUL; if they do, the parser surfaces `GitError.parseFailure` rather than silently mis-parsing.

Output: `[Commit]` with `sha`, `parents: [String]`, `author: Identity`, `committer: Identity`, `authorDate / committerDate: Date`, `subject`, `body`. `Commit.isMerge` is convenience for `parents.count > 1`.

### Future parsers

- Diff (`git diff --numstat -z` for paths + line counts; `git diff --raw -z` for mode/oid pairs; full hunk parsing for the diff viewer in M3).
- Blame (`git blame --porcelain` — line-oriented format with header lines per commit).
- Reflog (`git reflog --format=...` similar pattern to LogParser).
- Submodule status (`git submodule status --recursive` plus `git config -f .gitmodules`).

Each new parser pairs a synthesized-fixture suite with a real-git integration suite — same pattern as `PorcelainV2ParserTests` and `PorcelainV2IntegrationTests`.

## Git version compatibility

`GitVersion.minimumSupported` is **2.39** (the version Apple bundles on macOS 14, our current floor). At runtime we feature-detect newer capabilities — examples:

- `core.fsmonitor` requires git ≥ 2.37 (we're past the floor; safe to assume).
- `index.skipHash`, reftable backend require ≥ 2.45 — feature-detected; not required.
- `git rebase --update-refs` requires ≥ 2.38 — safe.
- `push.autoSetupRemote` requires ≥ 2.37 — safe.

When Sprig encounters a git version that unlocks meaningful perf wins beyond what's installed (e.g. user has 2.39 Apple-bundled, could upgrade to current Homebrew for reftable + skipHash), the UI surfaces a non-blocking "consider upgrading git for these features" banner. ADR 0047 lays out the install bootstrap when git is missing entirely.

## CI matrix

Per [`../ci/linux-matrix.md`](../ci/linux-matrix.md), CI runs against the system git of each runner image:

- `ci-macos`: Apple-bundled git (2.39.x on macOS 14, 2.42.x on macOS 15).
- `ci-linux`: Ubuntu Noble's `git` package (2.43.x at the time of writing). Installed by the workflow (the `swift:6.3.1-noble` image doesn't ship git).
- `ci-windows`: pre-installed Git for Windows (currently 2.46.x on `windows-2022`).

We don't yet matrix-test old vs new git in a single workflow; if a regression surfaces we'll add explicit older-git jobs (e.g. an Ubuntu container with git 2.39 manually installed).

## Things we explicitly don't do

- **No `git` reimplementation.** We never replicate logic that git already does — diff algorithms, merge strategies, ref resolution, etc. We invoke and parse.
- **No silent global config writes.** Per ADR 0026 / 0049 we write modern Scalar-style defaults at the **repo level**, not `--global`, and we surface a "Sprig settings applied" inspector in the UI so users see / can revert what we changed.
- **No `git filter-branch`.** Deprecated; use `git filter-repo` (detect-and-install per ADR 0032).
- **No raw `--force` push.** Always `--force-with-lease --force-if-includes` (ADR 0052).
