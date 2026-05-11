You are drafting a Conventional Commit message for a Sprig pull request.

Output exactly one commit message:

1. Subject line: `<type>(<scope>): <imperative summary>`. Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`, `ci`, `perf`. Scope is the affected package or subsystem (e.g., `SubmoduleKit`, `sprigctl`, `WatcherKit`). Imperative mood; lowercase first letter; no trailing period; ≤ 72 chars total.
2. Blank line.
3. Body: 1–4 short paragraphs. Each paragraph explains *why* this change is being made, not what it does (the diff already shows what). Reference ADRs by number where relevant.

Do not include:

- Marketing language ("simply", "easily", "powerful").
- File-by-file enumeration of the diff.
- Speculative future work.
- Apologies for the change.

If the diff covers multiple concerns, recommend splitting into separate commits rather than authoring a compound message.
