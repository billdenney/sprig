# sprigctl — the CLI surface

`sprigctl` began as the M1 diagnostic companion ("dump the parsed porcelain"). It has
grown into **a supported product surface**: until the GUI shells land it is the only
complete user-facing Sprig, it exercises every engine path with real-world miles, and
each task-window view model gets a CLI face as a matter of course (CLI/shell parity —
the same `TaskWindowKit` code drives both). This page is the index; `--help` on any
subcommand is authoritative for flags.

Scope boundary: sprigctl is OS-agnostic (`cli/`, no UI imports, ADR 0048 rules apply)
and deliberately *not* a general git porcelain — it surfaces Sprig's verbs (safety
pairing, vocabulary, ask-less defaults included), not raw git.

## Subcommands (engine-0.5.0)

| Command | What it does | ADRs |
|---|---|---|
| `version` | Build/version info. | — |
| `status [--summary] [--json]` | Parsed porcelain; `--summary` is the Status dashboard's data (branch relationship, tree counts, safety net, insight lines). | 0064, 0072, 0077 |
| `clone <url> [dir]` / `clone --browse --provider <p>` | Clone by URL, or pick from your forge repositories (token via the credential chain). | 0030, 0078, 0080, 0081 |
| `watch` | Stream watcher events (diagnostic). | 0024 |
| `repos` | Repo discovery/registration surface. | — |
| `log` | Parsed history (`--json` wire shape). | — |
| `sync [--push] [--rebase-diverged]` | Fetch → fast-forward → plain push; explicit diverged-rebase second act. Never forces. | 0068, 0071 |
| `agent [--preferences P] [--socket S \| --pipe N]` | The background agent: watcher + badge events + preferences-driven jobs, serving IPC on UDS (Linux/macOS) or named pipes (Windows). | 0067, 0068, 0075, 0076 |
| `backup [--list \| --restore <ref>]` | ADR 0075 uncommitted-work insurance. | 0075 |
| `recover [--list \| --restore <ref>]` | One list of snapshots + backups; restores that never eat work (stash-drop copies restore via `stash store`). | 0033, 0079 |
| `credential --set\|--get\|--remove --service <s> --account <a>` | Secrets via the user's git credential helper chain; `--set` reads stdin, never argv. | 0080 |
| `forge login\|logout\|status --provider <p>` | OAuth device-flow sign-in; tokens stored under `forge.<provider>`/`token`. | 0081 |
| `conflicts` | Unmerged-entry listing/classification (+ auto-resolve where safe). | 0034 |
| `lfs` | LFS detection/status surfaces. | 0029, 0035 |
| `submodule` | Submodule status surfaces. | — |
| `setup --global-ignore` | One-time global OS-noise excludes provisioning (never touches git config). | 0049 amendment |
| `diagnose` | Environment/report bundle. | — |

## Conventions

- **Repo argument:** most commands take an optional trailing repo path, defaulting to
  the current directory.
- **Exit codes:** 0 success; 1 carries meaning where scripting wants it (`forge status`
  not-connected, `credential --get` nothing-stored); validation errors follow
  ArgumentParser conventions on stderr.
- **Secrets** travel via stdin only (argv is `ps`-visible).
- **`--json`** where present is a deliberate wire shape (sorted keys, ISO-8601 dates),
  kept distinct from the Swift types so it can evolve independently.
- **Output registers:** human output uses the vocabulary's `.git` register (ADR 0072);
  several outputs are byte-pinned by tests — treat copy changes as contract changes.
