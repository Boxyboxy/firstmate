---
name: housekeeping
description: Reclaim disk taken by finished crew work - stale worktrees, and the containers, volumes, build cache, and images left behind by isolated stacks. Use when the captain invokes /housekeeping, asks to reclaim disk or clean up after finished work, or reports that the machine is low on space.
user-invocable: true
metadata:
  internal: true
---

# housekeeping

Finished crew work leaves disk behind: worktrees whose branches already landed, and the containers, volumes, build cache, and images their isolated stacks built.
Reclaiming it is routine.
Reclaiming the wrong thing is not: this sweep runs on the captain's own machine, next to work in progress and to stacks the captain is using right now.

The whole skill is therefore built on one asymmetry.
Keeping something that could have been deleted costs disk, which is the problem you are already solving and can solve again next week.
Deleting something that was in use costs the captain their running environment, and possibly unlanded work, which no later run can undo.
Every decision below resolves in favour of keeping.

`bin/fm-housekeeping.sh` owns the commands, flags, config paths, and exact classification order; read its `--help` rather than reconstructing any of that here.
This skill owns when to run it, what its output means, what you may decide alone, and what must go to the captain.

## Run the dry run first, always

Start with the default run, which deletes nothing and names exactly what it would reclaim.
Read all of it before proposing anything.
Nothing in this skill authorizes going straight to the delete path.

## The three protections, and why each exists

These are not hypotheticals.
Each one is an incident that already happened once.

### 1. A filter that matches nothing must never become a filter that matches everything

A manual sweep once built its protection list like this:

```
docker ps -q --format '{{.Names}}' | grep -v '^wffui-' | xargs -r docker rm -f
```

Docker prints `WARNING: Ignoring custom format, because both --format and --quiet are set` and emits container IDs instead of names.
The `grep -v` therefore protected nothing, and the pipeline removed all 17 running containers, including the captain's live localhost stack, which was serving on four ports at the time.
It came back in seconds only because that stack had its own rebuild script.

The script builds both its keep-list and its kill-list from names, never from IDs, and asserts by name that the two do not intersect immediately before it deletes anything.
It also refuses outright if the run concluded that no running container should be kept, or if the listing it read is not in the shape it expects.
Those refusals are the point of the tool.
A refusal is a correct outcome that needs a captain-facing explanation, never an obstacle to work around: do not hand-run the underlying docker commands to get past one.

### 2. Live work is off limits

A task with a metadata file in the active firstmate home is live, and its worktree, containers, and volumes belong to it.
The script cross-checks every container against that home's live tasks before proposing anything.
If you are working across homes, make sure the run reads the home whose work is actually running, or a live task will look finished.

### 3. A stack the captain is using is off limits, and it is detected structurally

A captain's local stack typically has its own directory with a `stack.sh` or equivalent status command, its own container-name prefix, and its own ports.
The prefix is not a good enough signal on its own, because the next such stack will use a different prefix and the sweep would not know about it.

The structural signals are a bound host port on a running container and a stack manifest on disk that claims a container, regardless of its name.
The configured keep-list is a second line of defence behind that, not the only one.

Anything the script cannot attribute is KEPT, never removed, and reported for the captain to judge.
Unattributable is not a delete reason.
When the report lists containers it could not attribute, relay them; do not add them to the keep-list on the captain's behalf, and do not decide they look disposable.

## The order the phases run in, and why

Phases run in ascending cost to re-acquire, so an interrupted run has spent the cheap reclaim first and the expensive reclaim last.

1. **Worktrees.**
   Treehouse already refuses to prune a worktree with uncommitted changes and reports it instead.
   That refusal is never overridden and never argued with: a skipped worktree is unlanded work, and this sweep has no authority to discard unlanded work under any flag.
   Failing closed whenever live metadata exists or changes was rejected because a normal active fleet would disable the phase exactly when cleanup is useful, while treehouse offers no atomic exclusion boundary.
   The remaining window is bounded to a worktree treehouse already considers stale and unleased, firstmate metadata considers live, and treehouse confirms is clean, so a loss costs a re-lease and never unlanded work.
   Report every skipped worktree to the captain by path, as work still sitting on the machine rather than as a housekeeping failure.
2. **Stopped containers**, then **dangling volumes**, then **build cache**.
   These are the cheap ones.
   Build cache comes back on the next build, but a volume can contain data that no rebuild restores.
   Losing a worktree costs a re-lease because uncommitted work is protected independently, while losing a volume costs data.
   The volume phase is therefore allowed to be slower and more conservative than every other phase.
   Requiring positive finished-task attribution was rejected because anonymous volumes carry no attribution, so that rule would remove the feature while pretending to protect it.
   The worktree phase's detect-and-report boundary is not reused here because no report can recover destroyed volume data.
   Deciding a destructive question from the shape of a string instead of an authoritative fact is the same defect class as the original filter failure.
   The volume phase keeps anything whose anonymity it cannot prove.
3. **Orphaned running containers with no live owner.**
   This is the only phase that stops something that is currently running, and it acts only on containers positively attributed to a task that has finished.
4. **Volumes again.**
   An orphan's volumes only become dangling once its container is gone, so the earlier volume pass could not see them.
   Skipping this rerun cost a real sweep 1.3 GB after it had already reclaimed 42.3 GB.
5. **Unused images, opt-in only.**
   Images are the largest reclaim and the most expensive to get back, and the base images live stacks rebuild from are among them.
   Include them when the captain has asked for space specifically, or when the dry run shows the reclaim is worth a slow first rebuild; otherwise leave them.

## Deciding

Running the dry run needs no permission: it deletes nothing.

The delete path always needs the captain's word, because removing containers, volumes, and images is destructive and this sweep runs on the captain's own machine.
An invocation that already asks to reclaim the space is that word; a bare `/housekeeping` is a request for the report, so send the report and wait.
Either way, name what would be stopped before stopping it: a running container, or unused images, is a bigger decision than build cache and must be called out separately rather than folded into a total.
A refusal always goes to the captain with its reason, because a refusal means the sweep saw something it could not make safe.

## Verify afterwards

A reclaim that broke the captain's environment is a failure even if it freed a lot of disk.
After the delete path, confirm every protected stack is still serving and note free space before and after.
The run re-checks that protected containers are still running; where a protected stack exposes a status command, use it to confirm service health.
The sweep this skill comes from went from 466 GB to 533 GB free.
If verification reports that a protected container is no longer running, say so immediately and plainly; that is a failure to report, not a detail to bury under the number of gigabytes reclaimed.

## Reporting

Report in the captain's terms, per `AGENTS.md` section 9: space reclaimed, what was kept and why, worktrees left alone because they hold unlanded work, and anything the sweep could not attribute.
Container IDs, image digests, volume hashes, and raw prune output are evidence you read, not the report you send.
