---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, or offline is skipped and reported.
A target sitting on another named branch keeps its checkout, index, and working tree untouched, but its default-branch ref still advances when that ref is free and the move is a strict fast-forward; the off-branch condition itself is still reported as a skip, because that checkout is what an operator has to repair.
Moving a default branch that a secondmate home shares with the wider firstmate repository is the primary checkout's job alone: a secondmate home off its own branch reports the condition and leaves that shared branch exactly where it is, so a secondmate sweep never moves the primary's branch under it.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `advanced <default> ref <old>..<new>` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next.
   A target on another named branch always prints a `skipped:` line naming the branch its checkout is stuck on, and adds a second line carrying the ref outcome when that outcome is `already current` or an advance; any other ref obstacle (the branch held by another worktree, an unreadable or diverged ref, or a failed update) is reported in the skip line itself, so a single line there is complete output rather than truncated.
   When the running firstmate itself shares its ref store with the wider repo, the ref outcome names the repository whose branch actually moved, because the move is not private to that checkout.
   A secondmate home in that position instead reports `<default> ref belongs to <repo> and moves only with that primary checkout`, and nothing moves.
   The action lines are:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Refresh the omp harness executable.**
   ```sh
   bin/fm-omp-update.sh
   ```
   This is the live update path, and the only path allowed to install: it replaces omp through whichever channel `which omp` already resolves, never a second private copy, and reports that channel plus the before and after versions.
   `omp` is one machine-wide executable, so swapping it can break any worker on this machine - not just this home's.
   The helper therefore installs only after confirming that every worker recorded here and in every registered local second mate home has stopped; a second mate reached over SSH runs on another machine and never blocks this one.
   When it refuses, it names exactly what it could not confirm stopped - a running worker, a record it could not classify, or a home or registry it could not read.
   Relay that to the captain and leave omp alone: the fleet is still up and the swap would break it.
   The unattended overnight cron never runs this step; it runs `bin/fm-omp-update.sh --check`, which is detect-only and can never install with nobody present to read a refusal.

5. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, or is offline is skipped and reported, never forced or stashed.
  A target on a non-default branch keeps its checkout exactly where it is and is still reported as skipped; only its free default-branch ref advances, and only as a strict fast-forward.
  A default-branch ref that another local copy has checked out - including one paused mid-rebase or mid-bisect on it - is left alone.
  A default branch shared with the wider repository moves only with the primary checkout, never under a secondmate sweep.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **The omp swap waits for a stopped fleet.**
  `bin/fm-omp-update.sh` replaces one machine-wide executable, so it installs only once every worker recorded in this home and in every registered local second mate home is confirmed stopped.
  Anything it cannot confirm - a live worker, an unreadable endpoint, an unreachable home, or an unreadable registry - is a refusal, not a reason to proceed.
  The unattended cron only ever checks.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
