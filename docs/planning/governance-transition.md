# Governance transition plan

How and when Sprig moves from BDFL (single maintainer) to open steering. Per ADR 0017 the transition target is "after 1.0, or earlier if 3+ steady contributors emerge." This file is the working draft of how that transition happens; it's drafted to ~50% by M7 and finalized before 1.0 if the trigger has fired.

ADR cross-references: 0015 (sustainability — pure FOSS + sponsorships, no paid tier), 0017 (BDFL → open steering).

## Trigger conditions

The BDFL → steering committee transition triggers when **either** is true:

- **Three or more contributors** have landed substantive PRs (>10 merged commits each, sustained over >3 months) and want ongoing involvement.
- **Sprig 1.0 has shipped** and stabilization is underway.

Whichever comes first.

## Pre-transition state (current)

- Single maintainer (BDFL) with final say on all decisions.
- All ADRs ratified by the maintainer.
- All releases signed with the maintainer's keys.
- All admin access (GitHub org, domain, signing certs, Apple Developer account, Microsoft Partner Center, sponsorship platforms) under the maintainer's control.
- Risk: high bus factor (R7 in `risk-register.md`).

## Post-transition state (target)

- A **steering committee** of 3–5 people with shared decision-making.
- A lightweight **RFC process** for substantive changes (anything that would warrant an ADR).
- **Two-key release signing**: at least two committee members hold release-signing material; releases require either's signature.
- Admin access split: GitHub org owners include all committee members; signing-cert custody distributed.
- A `MAINTAINERS.md` file lists committee members + rotation policy.
- The BDFL becomes "founding maintainer" — still a steering member, not a single point of failure.

## Transition mechanics

When the trigger fires:

1. **Announce intent** in a GitHub Discussion + maintainer's blog post. Solicit applications + nominations.
2. **Charter draft**. A short `GOVERNANCE.md` (currently a placeholder pointing at this plan) becomes load-bearing:
   - Committee size, term length, addition/removal mechanics.
   - Decision-making model (rough consensus + lazy consensus, as in the IETF / Apache style).
   - Conflict of interest disclosure.
   - Code of Conduct enforcement (separate from technical decisions).
3. **Initial committee selection**. Founding maintainer picks the first cohort from the contributor pool. Subsequent rotations follow the charter.
4. **RFC process bootstrap**. Adopt a lightweight RFC template (probably modeled on Rust's RFC process, scaled down). RFCs land in `docs/rfcs/` similarly to how ADRs land in `docs/decisions/`.
5. **Signing-key handover**. New committee members generate their own keys; an existing committee member adds them to the cert chain / Apple Developer team / Microsoft Partner Center / Sparkle EdDSA signers list.
6. **Comms surface**. Move from "the maintainer's discretion" to "open meeting cadence" — async, recorded, public. Probably a monthly "office hours" GitHub Discussion thread + a public chat channel (Matrix or similar).

## What's *not* changing at transition

- License (Apache-2.0 per ADR 0002) — fixed.
- Architecture invariants (CLAUDE.md "Hard rules") — only changeable via ADR.
- The portable-core / per-shell tier discipline (ADR 0048) — only changeable via ADR.
- The "no AI without explicit opt-in" privacy default (ADR 0036) — only changeable via ADR with extensive review.

## Relationship to corporate sponsorships (ADR 0015)

ADR 0015 ratifies pure FOSS + GitHub Sponsors / donations as the sustainability story. **No paid tier, ever.** Corporate sponsorships are surfaced in the README without granting decision-making influence. The steering committee is structurally independent of any sponsor.

If a sponsor wants a feature, they file an issue / RFC like everyone else. If they want to fund a contributor's time on a specific feature, that's negotiated case-by-case and disclosed in the RFC.

## Open questions

- **Committee size**. 3 is enough for redundancy but thin; 7 is robust but slow. Lean toward 5.
- **Term length**. Indefinite with self-removal? Annual rotation? Probably indefinite + lazy-consensus removal vote if a member becomes unreachable for 6+ months.
- **Conflict resolution**. What happens when committee members disagree and lazy consensus fails? Probably "founding maintainer breaks ties" through a transition period, then "rough consensus + escalation to a public vote" once the project's mature enough to have a meaningful contributor base voting.
- **Funding governance**. If sponsorships grow large enough to fund part-time work, who decides allocations? Likely a Treasurer role within the committee, with annual public reporting.

## Drafting timeline

| When | Action |
|---|---|
| M7 (AI integration milestone) | Refresh this doc; survey contributors-to-date for committee interest |
| M8 (Beta) | Draft `GOVERNANCE.md` charter; circulate for committee-candidate review |
| Pre-1.0 | If trigger has fired, transition. Otherwise hold until post-1.0. |
| Post-1.0 | If trigger hadn't fired pre-1.0, evaluate again. ADR 0017's "after 1.0" clause activates. |
