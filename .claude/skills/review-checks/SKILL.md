---
name: review-checks
description: Use when a spec is written, a plan is written, an implementation task or phase is finished, or before pushing a branch / opening a PR on claude-rc-menubar. Triggers include "spec done", "plan ready", "implementation complete", "ready to push", "open the PR", "before merge".
---

# Review checks

## Overview

Every phase boundary in the superpowers flow (spec → plan → implementation →
push) gets an **independent review before moving on**. Spec, plan, and
implementation checks dispatch **two reviewers with distinct assignments** —
one perspective misses what the other catches.

The recurring failure this prevents: finishing a phase and silently advancing
without dispatching the reviewers. **Do not advance a phase until its check has run.**

Dispatch the two reviewers in parallel — **REQUIRED SUB-SKILL:** use
superpowers:dispatching-parallel-agents. Keep each reviewer token-frugal
(tight prompt, structured findings back, no file dumps).

## The checks

| Check | Fires when | Reviewer 1 checks | Reviewer 2 checks |
|-------|-----------|-------------------|-------------------|
| **Spec** | a spec doc is finished | requirements complete, no "plan decides" deferrals, no open questions | contradicts the CLI's real behavior or existing repo docs? every CLI flag verified against `claude --help` output? |
| **Plan** | a plan doc is finished | steps correct & ordered vs the spec; tests exercise real production paths | every API/type/signature in plan code verified against the real source (Apple SDKs included), not assumed |
| **Impl** | an implementation task/phase is done | — see below — | — see below — |
| **Pre-push** | before `git push` / `gh pr create` / merge | cold review of the full branch diff (below) | — |

### Impl check

Use the superpowers code-review flow rather than re-inventing it:
- **REQUIRED SUB-SKILL:** superpowers:requesting-code-review (runs spec-compliance, then code-quality).
- **REQUIRED SUB-SKILL:** superpowers:receiving-code-review when acting on the findings — verify each before implementing, do not perform agreement.

### Pre-push check

Dispatch one token-efficient subagent with the branch diff. Its rubric:
correctness (does the diff do what the spec/plan says), `docs/ANTI-SLOP.md` for all
prose in the diff (commits, docs, comments, user-facing strings), and build +
test health (`swift build` and `swift test` ran green on the final state).
Have it return findings grouped by severity (`blocker` / `nit` /
`observation`).

The reviewer reviews cold: it gets the diff and the spec/plan goal — never the
implementer's rationale, approach summary, or "the maintainer approved this".
Primed context turns the reviewer into an execution checker.

```bash
git fetch -q origin && git diff origin/main...HEAD
```

Fix every `blocker` and `nit` **at the source** before pushing — the loop-ender
is the structural fix, not a half-fix that stays in the diff. An `observation`
is fixed in the running branch when the fix completes there (no open design
question, no verification the dev flow cannot run); genuinely separate scope
becomes an issue. Then push.

## Red flags — STOP

- About to write the plan, but the spec check never ran.
- About to write code, but the plan check never ran.
- About to `git push` / open a PR, but the impl check or pre-push review never ran.
- "I'll review after pushing" — review first.
- Dispatched one reviewer where the check needs two. Both assignments or the check did not run.

All of these mean: stop, run the check, then advance.

## Not for

- Trivial chore commits (a typo, a doc one-liner, a skill file) pushed straight to `main` — no phase, no review check.
