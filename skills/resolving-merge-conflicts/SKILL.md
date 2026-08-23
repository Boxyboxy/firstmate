---
name: resolving-merge-conflicts
description: Resolve git merge, rebase, or cherry-pick conflicts by tracing each side's intent, hunk by hunk - never by side-picking. Use whenever a merge or rebase stops on conflicts, a PR reports merge conflicts, or a task asks to merge one branch into another and resolve the conflicts.
user-invocable: true
---

<!-- maintainers: this is a public, installer-facing skill for worker agents on any harness. Keep it standalone, with no private project paths or harness-specific mechanics. Adapted from mattpocock/skills resolving-merge-conflicts (MIT) and extended with this fleet's merge lessons, stated generically. -->

# resolving-merge-conflicts

A merge conflict is a disagreement between two intents, not between two texts.
Side-picking is how a merge silently drops landed work, and a green suite afterwards proves the least of any available verification, so resolve by intent and verify against both parents.

## Before touching any hunk

1. Fetch first: `git fetch origin --prune`, then confirm the ref you are merging is the current remote tip.
   A stale local ref produces a clean-looking merge that silently misses commits, and it looks exactly like success.
2. See the whole state: `git status`, the conflicted file list, and `git log --oneline --left-right HEAD...MERGE_HEAD` (or the in-progress rebase's remaining todo), so you know which commits each side brings.
3. For every conflicted region, find the primary source of each side's intent: the commit message, the PR that introduced it, the linked issue or plan.
   You are choosing between two intents, and you cannot choose between intents you have not read.

## Resolving

4. Resolve hunk by hunk, preserving both intents wherever they can both hold.
5. Never resolve wholesale.
   `git checkout --ours`, `git checkout --theirs`, `-X ours`, `-X theirs`, and accepting one side across a whole file are all prohibited, because each silently deletes the other side's landed work.
6. Generated artifacts - lockfiles, snapshots, generated clients, compiled schemas - are regenerated with their generator after the source-level resolution, never hand-merged.
7. Never invent new behaviour inside a conflict resolution.
   A merge commit may contain only what one of the two sides already intended.

## When both intents cannot hold

8. If the conflicting hunk touches a shared contract surface - a cross-repo payload or envelope, a published API response shape, a compliance or enforcement path, a migration chain - stop and escalate the choice as a decision to whoever supervises the task, with both intents stated.
   A contract change must never be settled silently inside a merge commit.
9. Otherwise pick the side that matches the merge's stated goal, and record the trade-off - what was dropped and why - in the merge commit body and the PR description.

## Verifying

10. Diff the merge result against both parents (`git diff HEAD^1`, `git diff HEAD^2`) and confirm each parent's intended changes survived.
    The absence of conflict markers verifies nothing.
11. Discover and run the project's own documented checks, and compare failure counts against the untouched base, because the base may not have been green before you started.
    On branches where CI does not trigger, "checks green" can mean "no checks ran" - read what actually ran rather than trusting a green badge.
12. Finish the operation: commit the merge, or continue the rebase until every commit is replayed.
    If you cannot finish safely, stop with the repository left in its conflicted state and report exactly which hunks are unresolved and why - a half-resolved merge presented as done is worse than an honest stop.
