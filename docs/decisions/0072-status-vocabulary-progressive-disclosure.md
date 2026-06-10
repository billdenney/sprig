---
status: accepted
date: 2026-06-10
deciders: maintainer (beginner-affordances directive 2026-06-09), engineering
consulted: —
informed: —
---

# 0072. Status vocabulary — one formatter, two registers, progressive disclosure

## Context and problem statement

Affordances item 2.1: a beginner reads "behind origin/main by 2" as noise, but a UI that
*hides* git vocabulary produces users who can never collaborate outside Sprig. The chosen
stance is progressive disclosure: everyday words first, the git term taught in parentheses —
"your copy is 2 update(s) behind origin/main (git: behind by 2)" — so users graduate into
the vocabulary.

Meanwhile the engine has been accumulating typed outcomes (`FastForwardOutcome`,
`PushOutcome`, `PreflightWarning`, `SetAsideOutcome`, `BranchSyncState`) and the copy for
them was scattering: `sprigctl sync` had three private `describe()` functions, and each shell
would have grown its own. Two problems, one structure.

## Decision

**`UIKitShared.StatusVocabulary` is the single formatter from typed engine outcomes to
user-facing copy, in two registers:**

- **`.plain`** — the beginner register. Plain words first; wherever a git term exists it is
  taught in parentheses (`(git: …)`). Never mentions CLI flags. Spares raw git stderr where
  it would be gobbledygook (e.g. a kept-stash banner says "your changes are saved", not
  `CONFLICT (content)…`).
- **`.git`** — the terse git-native register: exactly sprigctl's existing output (its
  end-to-end tests pin the strings — the migration of `sprigctl sync` to the vocabulary
  passed those tests unchanged, byte-for-byte), and the shells' power-user reveal level.

House rules encoded in the type:

- **View models never format.** They expose typed outcomes; shells + the CLI ask the
  vocabulary. (ADR 0048 keeps VMs portable; this keeps them presentation-free too.)
- **Register selection is the consumer's concern**: sprigctl always `.git`; shells map
  ADR 0019's reveal level to a register.
- **No locale-dependent formatters.** Byte sizes use integer math (`57.2 MB` with a hard-coded
  `.`), so output is deterministic across platforms and CI environments.
- **Safety language is part of the contract**: push-rejection copy must state that Sprig never
  forces, in both registers (unit-tested).
- **Localization surface.** English-only at 1.0 (ADR 0042); when localization lands, this is
  the file that grows string tables — consumers don't change.

`UIKitShared` (previously an empty Tier-1 stub) gains its first real content and the
dependency direction `UIKitShared → {GitCore, TaskWindowKit}`: it sits *above* the view-model
layer, consumed by shells and sprigctl.

## Considered options

1. **Central two-register vocabulary** (this ADR).
2. Strings on the outcome types themselves (`description` / `CustomStringConvertible`) — ties
   presentation to plumbing types in GitCore, gives exactly one register, and makes the
   eventual localization surface the plumbing package. Rejected.
3. Per-shell string tables — duplicates copy three ways (macOS/Windows/CLI) and guarantees
   drift; the CLI's strings were already on that path.
4. A single "friendly" register only — abandons power users and breaks sprigctl's pinned
   output; the two-register shape costs one enum.

## Consequences

- Every existing typed outcome now has reviewed beginner copy ready for the shells; new
  outcome cases fail to compile until vocabulary cases are added (exhaustive switches).
- `sprigctl sync` shrank by its three private formatters with provably identical output.
- The remaining 2.1 scope — applying the plain register across badge tooltips and the other
  task windows — rides with each shell surface as it lands (M2/M3); the infrastructure and
  precedent are set.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 2.1 (infrastructure + first
  consumers).
- ADR 0019 (reveal levels pick the register), 0042 (localization later; this is its surface),
  0048 (tier discipline; new Tier-1→Tier-1 deps), 0052/0071 (the never-force language this
  vocabulary enforces), 0069/0070 (the outcome types being formatted).
