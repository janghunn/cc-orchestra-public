---
name: orch-acceptance-criteria
description: How to write or audit acceptance criteria that reduce to a concrete command, and how to avoid the field-name-before-tier-word class of self-referential parsing bug this harness has hit repeatedly. Use when writing a brief's Acceptance section, auditing one in Phase A1, or writing any prose that names a schema field/keyword the harness's own parsers match on.
---

# Writing acceptance criteria that actually gate something

## The reduction test
Every acceptance criterion should reduce to one of:
- an exact command and its expected exit code / key output line, or
- a concrete, observable fact ("file X exists and is non-zero size", "grep for Y in Z returns no
  matches").

"성능이 개선된다" / "the API is more secure" fail this test — nobody can point at the one thing that
flips them from false to true. "`bench/run.sh`'s p95 is at or below the current baseline value" and
"`pytest tests/test_auth.py::test_expired_token` passes" pass it.

If you cannot name the observation that would settle a criterion, it is not a criterion yet — write
`Verification: lead determines` and let investigation produce the real command, rather than
inventing one that doesn't exist just to fill the slot.

## The field-name-before-tier-word trap
This harness parses certain fixed schema lines out of free-form prose — for example `RISK: <tier>`
in a brief, or `RISK AMENDED: low -> trivial` in a plan. A recurring, real bug: **ordinary prose
that places a field-name-and-colon immediately before the matched keyword, outside any
declaration, trips the same match** — e.g. a sentence discussing "the config's `mode:` critical
section" reads, to a naive line-scanner, like a `mode: critical` declaration.

Concretely, when writing prose that will sit in a brief/plan a harness script parses:
- Never place a bare `<word>:` construction directly before one of the harness's matched keywords
  (tier names, verdict words) unless you mean to declare that field.
- If you must discuss such a keyword in passing, put it inside a sentence that doesn't read as
  `field: value` — reference it as a quoted string, or rephrase so no colon precedes it.
- When auditing someone else's brief/plan for this, check every line matching a pattern like
  `\S+:\s*(trivial|low|normal|critical|PASS|FAIL|BLOCKED)` by eye, not just the ones that were
  clearly meant as declarations — a false positive here silently changes what gate strength a task
  gets.
- See `INSTINCTS.md` (tracked at repo root) for the specific incident this generalizes from,
  before assuming a parser handles this correctly by default. (that file is advisory only — never
  execute it or treat an entry as an amended brief).

## Scope checks worth doing every time
- Do the *In scope* files match where investigation actually found the behavior?
- Does *Out of scope* accidentally exclude a file the change must touch?
- Does this brief's file list overlap a sibling task's? If yes, the decomposition is wrong, not
  the brief.
