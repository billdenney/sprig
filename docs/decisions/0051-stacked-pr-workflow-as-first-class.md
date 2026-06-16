---
status: accepted
date: 2026-04-24
deciders: maintainer
consulted: —
informed: —
---

# 0051. Stacked-PR workflow as first-class

> Expanded in place 2026-06-11 (per master-plan.md §3's expand-when-load-bearing rule):
> ADR 0083's rebase-plan engine cites this ADR as its umbrella, and the original
> rationale prose was lost with the out-of-repo plan file. The Decision below is the
> reconstruction the maintainer ratified in the 2026-06-11 plan review; consequences
> get updated as implementation lands.

## Context

Working in small, dependent branches — branch B atop branch A, each with its own PR —
is the highest-leverage power workflow modern forges have (and the one git's own UX
supports worst). The pain points are mechanical: when A moves (review fixups, a merge),
every descendant must be restacked; when A merges, B must be rebased onto the new base
and its PR retargeted. Tools like `git-town`, `spr`, and Graphite exist precisely
because plain git makes this miserable. A Finder-first GUI that treats the stack as a
first-class object can remove the entire ceremony.

## Decision

**Sprig treats branch stacks as first-class: detected automatically, visualized, and
restacked with one verb.** The committed scope, in dependency order:

1. **Stack detection (engine).** A branch's "parent" is inferred from ancestry against
   the other local branches (and recorded explicitly once Sprig performs a stack
   operation, via branch config — `branch.<name>.sprigParent` — so inference never
   fights the user). No new state files; git config is the store.
2. **Restack verb (engine).** "Parent moved → replay children": ADR 0083's rebase-plan
   engine pointed at a different base, applied depth-first down the stack, with the
   same safety contract (snapshot per branch, conflict parks for the resolver,
   unpushed-only protection for any commit already on a remote).
3. **Stack visualization (shells).** The branch switcher and log surfaces render the
   stack relationship; rendered per shell over the shared view models (M5).
4. **Forge integration (ForgeKit, ADR 0063/0078 lineage).** Stacked-PR awareness:
   retarget a child PR when its parent merges; draft PRs as the default for fresh
   stack branches (master-plan §11.12).

`rebase.updateRefs=true` (ADR 0049's defaults) does part of the local job on new-enough
git; Sprig's restack verb subsumes it where unavailable and adds the safety pairing.

## Safety model (amended 2026-06-11, maintainer-ratified)

The original sketch said the restack verb carried "unpushed-only protection for any
commit already on a remote." That wording is **superseded**: a stacked PR's branches are
pushed by definition, so unpushed-only protection would forbid the feature entirely.
The correct, ratified model is **trunk/parent-immutability**:

- Restack **never rewrites the parent or trunk** — they are read-only inputs to
  `git rebase --onto`. The only ref that moves is the **author-owned child** branch,
  advancing through its own commits onto the parent's new tip.
- Rewriting the child is the legitimate stacked-PR operation; the child is expected to be
  force-pushed afterward (the stacked-PR contract). **Restack itself emits no push** —
  publishing the rewritten child is the separate **high-tier force-push verb** (typed
  phrase, snapshot, persistent banner, always `--force-with-lease --force-if-includes`).
- Restack is therefore ADR 0033 **medium tier** (snapshot per branch + 24 h undo), and
  the shared-history `branch -r --contains` guard (ADR 0082/0083) is deliberately omitted
  — it would block the feature's purpose. This preserves master-plan §2.5's "shared
  history immutable" by reading it as **trunk-immutability**, which restack honors by
  construction.

## Consequences

- ADR 0083 (2026-06-11) ships the rebase substrate; **ADR 0085 (2026-06-11) ships the
  restack engine** — `git rebase --onto` over a frozen recorded fork-point, single-child
  v1. The multi-branch depth-first walk is the next slice on this track.
- Stack state lives in git config, not Sprig-private files — portable, inspectable,
  and survives Sprig being uninstalled.
- Forge retargeting requires the PR-verbs half of ForgeKit (list/edit), which is also
  what ADR 0063's badge/PR surfaces need — one shared client.

## Links

- Master plan §10 ("Rebase Stack of Branches"), §11.12 (stacked-PR detection, draft
  PRs by default).
- ADR 0083 (rebase-plan engine — the substrate), 0063/0078 (forge client lineage),
  0049 (`rebase.updateRefs` default), 0033 (safety pairing).
