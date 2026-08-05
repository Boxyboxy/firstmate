---
name: omp-firstmate-leverage
description: >-
  Recurring maintenance for a firstmate running on omp: update omp, fast-forward firstmate's default branch, merge it into the local omp adapter branch, and audit whether omp's current feature surface is actually reachable from firstmate.
  Use when the captain invokes /omp-firstmate-leverage, asks to update omp and firstmate together, asks whether firstmate is leveraging omp, or when the recurring backlog item for this sweep comes due.
user-invocable: true
metadata:
  internal: true
---

# omp-firstmate-leverage

Four steps, in order.
Each is independently useful, so a failure in one does not abandon the rest - record it and continue.

Stop and report instead of improvising if any step needs a decision the captain has not already made.

## 1. Update omp

Record the version before and after.
Install through whatever channel `which omp` resolves to; do not switch channels.

An omp update is a dependency change for a running firstmate, so treat a major or minor bump as a
trigger for step 4 even when nothing else changed.

## 2. Fast-forward firstmate's default branch

`/updatefirstmate` owns this exactly.
Load and follow that skill rather than restating its guards here.
It fast-forwards this home and every registered secondmate, never forces, and never touches `projects/`.

## 3. Merge the default branch into the omp adapter branch

The captain maintains a long-lived local adapter branch (`feat/omp-adaptor` at the time of writing;
confirm the current name from `config/` or by asking, never assume).

Merge, never rebase - it is published and other work is built on it.
This is firstmate's own repo, so when the fleet is empty firstmate may do it directly; when any
crewmate is live, delegate it per `AGENTS.md` section 1.

Resolve conflicts on the merits and keep the primary checkout's tangle rule in mind: if the merge
leaves the primary on a feature branch, restore it afterwards.

## 4. Audit whether omp's features are actually reachable from firstmate

This is the step with real value, and the one most likely to be skipped because it has no obvious
finish line. Do it every time.

The question is not "does firstmate work on omp" but **"what can omp do that firstmate never asks it
to do"**. Read `omp --help` and `omp config list` against what `bin/fm-spawn.sh` actually builds.

Known checkpoints, each verified against the launch template rather than assumed:

- **Role models.** omp resolves distinct models per role - `smol`, `slow`, `plan`, `task`, `commit`,
  `tiny`, `designer`, `advisor`, `vision`. If the captain has configured `modelRoles` but the spawn
  template passes only `--model`, every crewmate runs one model for planning, editing and commit
  messages alike, and the configured split is inert for the whole fleet.
- **Prewalk.** `--prewalk` steps down to a cheap model at the first edit after the plan's todo list
  exists. That is the exact shape of a fix round. Check `prewalk.enabled` and whether the template
  passes it.
- **Session flags.** `--no-session`, `--max-time`, `--approval-mode`, `--profile`, `--add-dir`.
- **Extension and hook surface.** `-e` / `--hook`, and the tracked `.omp/extensions/` auto-discovery
  root, against what the adapter wires for busy state and turn-end.

**The harness trap - check this before proposing any role or prewalk work.**
omp's role map applies only to crewmates actually launched on the omp harness. If
`config/crew-harness` or the matched `config/crew-dispatch.json` profile routes crew to claude or
codex, wiring role flags into the omp template changes nothing at all.
So an omp-leverage recommendation is only real when it names both halves: the dispatch change that
puts crew on omp, and the adapter change that uses the roles. Proposing the adapter half alone is a
false economy and has already been pitched once in error.

Weigh a dispatch change against `data/captain.md`, which owns the model-split and resource
preferences, and against current `quota-axi` output. Do not move the fleet onto a harness whose
budget cannot carry it.

## Output

A short report: omp version before and after, whether the fast-forward and merge succeeded, and the
leverage findings as concrete gaps - each naming the omp capability, the firstmate surface that would
have to change, and whether a dispatch change is also required for it to matter.

File anything worth doing as a backlog item rather than fixing it inside this sweep.
The sweep observes and reports; it does not redesign the adapter on a schedule.
