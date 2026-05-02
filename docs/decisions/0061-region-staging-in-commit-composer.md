---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0061. Sub-hunk / region staging in CommitComposer

## Context and problem statement

Sprig's planned CommitComposer task window stages changes per-hunk by default (the standard GUI pattern). The competitive review (master plan §13.3-C) finds that **region staging — selecting arbitrary text inside a diff and staging exactly that selection — is the killer power-user feature that almost no GUI replicates.** Magit ships it; Sublime Merge has line-level (a partial step); Fork has hunk-only. Magit users repeatedly cite this when explaining why the GUI-to-CLI bridge fails for them.

Region staging is the bar for power-user discoverability: it tells users "Sprig understands diffs, not just files." Implementation cost is moderate — the algorithmic core is "given a diff and a byte-range selection, emit the patch that applies just that selection" — but the cost is isolated to one component. Once region staging works, sub-hunk and line-level staging come for free.

## Decision drivers

- Make Sprig's CommitComposer the most powerful staging surface in any GUI.
- Cost is bounded: one new diff-parsing utility in `GitCore` plus UI in CommitComposer.
- Bridges the audience split with ADR 0058's transient chips: power users get full control; novices keep the simple "stage hunk / stage file" buttons.

## Considered options

1. **Region staging (Magit parity)** — this ADR. Click-and-drag in a diff to select text; "Stage selection" button stages exactly that.
2. Line-level staging only (Sublime Merge parity). Click individual lines or shift-click a range; "Stage lines" stages those. Easier to implement; covers ~80% of use cases.
3. Stay at per-hunk + add "Split hunk smaller" (rerun `git diff` with smaller context). Coarser; works for most edits.
4. Defer past 1.0 — per-hunk only at 1.0; revisit if power-user demand surfaces.

## Decision

**Option 1 (region staging, Magit parity).** CommitComposer supports three-tier staging:

1. **Stage file** (existing — the file-list checkbox).
2. **Stage hunk** (existing — the per-hunk button).
3. **Stage selection** (new) — the user clicks-and-drags within the diff text to select arbitrary characters / lines / hunks; the "Stage selection" button (visible when a non-empty selection exists) stages exactly that.

### Algorithmic core

A new utility in `GitCore`:

```swift
public enum DiffPatchSlicer {
    /// Given a `git diff` (unified format) and a byte-range
    /// selection in the rendered diff text, produce a patch that —
    /// when fed to `git apply --cached --recount` — stages exactly
    /// the selected hunks/lines.
    ///
    /// The selection respects diff structure: selecting half a `+`
    /// line stages the whole `+` line (you can't half-add); selecting
    /// inside the file header stages nothing (header isn't a change);
    /// selecting across hunks emits a multi-hunk patch.
    public static func patch(from diff: String, selection: Range<String.Index>) throws -> String
}
```

The implementation is a small parser that walks the unified-diff structure (`@@` hunk headers, `+`/`-`/` ` line prefixes), maps the rendered-text selection back to source-diff lines, and emits a new patch string with only the selected lines retained (and re-counted hunk headers).

### UI

- The diff renderer in `CommitComposer` (a `TaskWindowKit` view) supports text selection via standard mouse/trackpad drag.
- A floating "Stage selection" button appears anchored near the selection's end when the selection is non-empty and intersects diff content.
- The button's command preview (per ADR 0057's Commands panel) shows the literal `git apply --cached --recount` invocation Sprig will run, with the patch payload truncated to a sensible length and a "Show full patch" affordance.
- Keyboard shortcut: `⌘⇧S` (macOS) / `Ctrl+Shift+S` (Windows). Discoverable via the command palette (ADR 0040).
- Screen reader announces "Stage selection: 3 added lines, 1 removed line in foo.txt" so the affordance is a11y-complete (per ADR 0042).

### What the selection can stage

- A range entirely inside a single hunk → that subset of the hunk.
- A range spanning multiple hunks in one file → multiple hunk slices, one patch.
- A range spanning multiple files → emit a multi-file patch.
- A range starting in headers / context-only lines → button disables with hover-tooltip "Selection contains no changes."

### Round-trip

After staging, the diff re-renders from the new index/working-tree state. The selection is cleared. Per ADR 0033, the operation is reversible via the snapshot ref + `git restore --staged --patch`.

## Consequences

**Positive**
- Closes the largest single power-user-discoverability gap surfaced in the competitive review.
- Pairs with ADR 0058 (transient chips) and ADR 0057 (Commands panel) to make CommitComposer the most powerful committed-change-construction UI in any 2026 GUI.
- Implementation is contained: one `GitCore` utility + UI changes in one task window.
- The same `DiffPatchSlicer` is reusable in MergeConflictResolver (ADR 0027) and in any future "apply hunk to other branch" affordance.

**Negative / trade-offs**
- Diff-text-selection-to-source-patch mapping is fiddly when the renderer adds visual decorations (line numbers, syntax highlighting, soft-wraps). Tests must cover round-trips of selection → patch → re-render to catch regressions; integration tests in `tests/integration/CommitComposerSelectionTests/`.
- `git apply --cached --recount` requires the patch's hunk headers to be approximately right; the slicer must emit valid hunk-header counts. Edge cases: empty hunks (skip), empty selections (button disabled), selections crossing CRLF boundaries on Windows (test with `core.autocrlf=input` as default per ADR 0049).
- Performance on very large diffs (>10k lines) needs profiling; benchmark gate adds `tests/benchmarks/CommitComposerStaging/` to ADR 0021's budget.

## Links

- Master plan §13.3-C.
- Related ADRs: 0027 (3-way merge view — same `DiffPatchSlicer` utility), 0033 (snapshot ref makes staging operations reversible), 0040 (command palette exposes the keyboard shortcut), 0042 (a11y), 0057 (Commands panel renders the `git apply` invocation), 0058 (transient chips paired UX), 0049 (CRLF defaults).
- Magit reference: <https://magit.vc/manual/magit/Staging-and-Unstaging.html>
