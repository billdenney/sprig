---
status: accepted
date: 2026-06-11
deciders: maintainer ("lean in further and proceed", 2026-06-11), engineering
consulted: —
informed: —
---

# 0077. Status insight lines — "what changed?" digest + stale-work nudge

## Context and problem statement

Two Tier-3 beginner affordances answer questions the user would otherwise have to ask git
themselves, in the spirit of the ask-less principle (answer before asked; never interrogate):

- **3.3** — when auto-fetch moves a remote-tracking ref, the badge counts change with no
  explanation. "12 new commits from 3 people on origin/main" turns an opaque state change
  into a sentence.
- **3.1** — work parked on a branch silently ages. "feature/x has 4 changed files waiting —
  nothing committed in 9 days" surfaces it, only inside the Status window the user opened
  (no notification spam, per ADR 0014's restraint).

## Decision

**Both ship as Status-window data + vocabulary lines, computed from plumbing the engine
already runs adjacent to.**

- **`SyncOps.fetchAllDigesting()`** — snapshot the remote-tracking tips
  (`for-each-ref refs/remotes/` with `%(symref)` filtering so `origin/HEAD` can't
  double-digest its target), fetch, snapshot again, and digest each moved ref with ONE
  `git log --format=%an old..new` spawn (line count = commits, distinct count = authors).
  Brand-new and deleted refs are skipped — the digest answers "what's new on branches I
  already track". A non-fast-forward remote movement undercounts via `old..new`; accepted —
  this is a summary line, and the diverged report owns the rewrite case.
- **`RepoStatusSummary`** gains `fetchDigests` (from `fetchNow()`; nil until a fetch runs)
  and `lastCommitDate` (`git log -1 --format=%cI`) — the shells compute "9 days" against
  their own clock and show the 3.1 nudge only when the dirty counts make it worth saying.
- **`StatusVocabulary`** words both lines in both registers, no `(git:)` parentheticals
  (neither is a ratified teaching point; the census test enforces).
- **`sprigctl sync`** prints `fetched: <digest>` lines (`.git` register) when its fetch
  moved refs — CLI parity for free since it shares the engine call.

## Considered options

1. **Tip-snapshot diffing around the existing fetch** (this ADR) — no fetch-machinery
   changes, one extra for-each-ref pass per fetch.
2. Parsing `git fetch`'s stderr ref-update lines — locale/format-fragile, and `--quiet`
   (which we keep for the agent) suppresses them.
3. `FETCH_HEAD` inspection — auto-fetch deliberately runs `--no-write-fetch-head`
   (ADR 0068); reversing that for a summary line is the tail wagging the dog.
4. AI summarization of the new commits — rejected on the standing non-AI directive; counts
   are deterministic and answer the actual question.

## Consequences

- The agent's hourly fetch gains a user-visible explanation the moment the M3 Status window
  renders summaries; `sprigctl sync` users get it today.
- One `for-each-ref` + one `log` per *moved* ref of overhead per fetch — negligible against
  the fetch's own network round-trip, nothing on the no-movement path but the ref snapshot.
- `fetchAll()` stays as-is for callers that don't want digests (the agent job keeps its
  current shape until the Status window consumes digests through the host).

## Links

- Implements `docs/research/git-beginner-affordances.md` items 3.1 + 3.3.
- ADR 0014 (notification restraint), 0064 (Status window home), 0068 (the fetch being
  digested), 0072 (vocabulary registers), 0049 amendment (the ask-less principle).
