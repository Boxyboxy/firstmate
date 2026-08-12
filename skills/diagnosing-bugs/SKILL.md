---
name: diagnosing-bugs
description: Reproduce-first bug diagnosis - build a feedback loop that goes red on the bug before theorising, then minimise, hypothesise, instrument, fix, and prove red to green. Use when investigating a reported bug, regression, flaky test, or unexplained behaviour, and before writing any fix for one.
user-invocable: true
---

<!-- maintainers: this is a public, installer-facing skill for worker agents on any harness. Keep it standalone, with no private project paths or harness-specific mechanics. Adapted from mattpocock/skills diagnosing-bugs (MIT), reduced to the loop-construction core and extended with this fleet's verification lessons, stated generically. -->

# diagnosing-bugs

Theories formed before a reproduction exists are guesses, and fixes built on guesses solve the wrong problem convincingly.
The gate of this skill: no red-capable command, no diagnosis.

## Phase 1 - build a loop that goes red on this bug

Construct one command that runs unattended, goes red on the bug now, and will go green when the bug is fixed.
Prefer the highest entry on this menu that fits:

1. A failing automated test.
2. A direct API call with an asserted response.
3. A CLI invocation plus a snapshot diff.
4. A headless browser script.
5. A replay of a captured trace, payload, or fixture.
6. A throwaway harness script.
7. A property or fuzz loop.
8. A bisection harness (`git bisect run` with the loop as the verdict).
9. A differential loop: the same input through the working and the broken path, diffing outputs.
10. A human-in-the-loop script - last resort only.

Rules for the loop:

- Reproduce the symptom the way the end user hits it, end to end where feasible, so the loop captures the real problem and not a proxy for it.
- Before hand-rolling anything, look for an established harness in the repo, and check whether it accepts a ref or flag for the code under test before declaring something unrunnable.
- Tighten until an iteration takes seconds, not minutes - iteration rate is diagnosis speed.
- For a non-deterministic bug, raise the reproduction rate (run the loop N times, control seeds and timing) instead of chasing one clean reproduction.

## Phase 2 - minimise

Remove elements - flags, fixtures, steps, data - until every remaining one is load-bearing, meaning removing it makes the red go away.
What remains is the actual shape of the bug.

## Phase 3 - hypothesise before instrumenting

Write three to five ranked falsifiable hypotheses before testing any of them.
Each must name the observation that would disprove it.

## Phase 4 - instrument one variable at a time

Add instrumentation for one hypothesis at a time, and tag every temporary line with one unique marker (for example `[DEBUG-4f2a]`) so cleanup is a single search.
An instrument that cannot distinguish between two hypotheses is noise; move it or remove it.

## Phase 5 - fix, and prove red to green

- Run the loop red on the pre-fix code and green on the fixed code, and show both outputs.
- If proving the test can fail requires reintroducing the bug, that reintroduction is temporary: revert it completely before committing, and prove with a diff against the pre-mutation head that only the intended fix remains.
- Name the referent of the green run: which commit, branch, or build did it exercise?
  A green run against a stale checkout, stale pin, or wrong ref looks like proof and is weaker than no run at all.

## Phase 6 - regression test and cleanup

- Convert the reproduction into a regression test where a test seam exists.
  If no seam exists, say so explicitly - the missing seam is itself a finding worth reporting.
- Remove every tagged instrument and scratch harness before committing; the final diff should contain the fix and the regression test, nothing else.
