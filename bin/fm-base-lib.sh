#!/usr/bin/env bash
# fm-base-lib.sh - the single owner of what a task base may be.
#
# A crewmate's base is stated by bin/fm-brief.sh (which renders it into the
# brief and derives the PR target from it) and cut by bin/fm-spawn.sh (which
# fetches it, resolves it and records it). Those two must never disagree about
# which values are admissible: a base a brief accepts but its spawn refuses
# leaves a scaffolded brief that can never be launched, and the reverse hands a
# worker a brief whose stated base its spawn never validated. The rule therefore
# lives here, in code both scripts source, rather than as a comment in each
# asking the other to stay in step.
#
# --base deliberately accepts ONE shape, a branch on origin written
# "origin/<branch>", and refuses every other shape before a worktree is touched.
# The reason is the whole point of this contract: a base has to be provable as
# current against the remote, and nothing else can be. `git fetch origin` writes
# refs/remotes/origin/* and nothing else, so a local branch, an explicit
# refs/heads/* ref, or another remote's ref resolves cleanly while sitting
# arbitrarily far behind; a tag or a raw commit has no branch a PR could target;
# and a revision expression (main~1, main^, main^0, main@{0}, HEAD~1) silently
# anchors on whichever of those refs it names, which is how a stale local branch
# got in once already. This narrowness is deliberate rather than an oversight:
# every real dispatch names a branch, so a caller with a genuine need for another
# shape should reopen this decision rather than find the capability pre-supported
# and unprovable.
#
# A second class is refused separately because it passes the character screen
# while still failing to name a branch. The PR target is derived by stripping the
# leading "origin/", so "origin/HEAD" would yield the target "HEAD",
# "origin/refs/heads/x" would yield "refs/heads/x" and "origin/origin/x" would
# yield "origin/x" - none of which is a branch a forge can be asked to merge
# into. origin/HEAD is a symbolic ref whose target moves with the remote's
# default branch, so it is exactly the guessed, unstated base this contract
# exists to eliminate. These are refused here, at the shape gate, so the caller
# is told to name the concrete branch instead of meeting an unrelated-sounding
# fetch failure later.

# Whether a base names a branch on origin in the one admissible form.
fm_base_shape_ok() {  # <base>
  local base=$1 branch

  case "$base" in
    origin/?*) ;;
    *) return 1 ;;
  esac

  case "$base" in
    *'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*|*'@{'*|*' '*) return 1 ;;
  esac

  # What the PR target derivation would produce. It has to be a branch name.
  branch=${base#origin/}
  case "$branch" in
    HEAD|refs/*|origin/*) return 1 ;;
  esac

  return 0
}

# Refuse a base that fm_base_shape_ok rejected, naming both the value passed and
# the concrete form that would have been accepted. <flag> lets a caller name the
# option the value arrived on, so a brief and a spawn each blame their own flag.
fm_base_shape_refuse() {  # <base> [flag]
  local base=$1 flag=${2:---base} branch

  branch=${base#origin/}
  case "$base" in
    origin/?*)
      case "$branch" in
        HEAD|refs/*|origin/*)
          echo "error: $flag must name a branch on origin as 'origin/<branch>' (got '$base'); '$branch' is not a branch name, so it cannot be cut from or targeted by a PR - origin/HEAD is a symbolic ref that moves with the remote's default branch, which is the unstated base this contract exists to eliminate; name the branch itself, for example 'origin/feat/omp-adaptor'" >&2
          return 0 ;;
      esac ;;
  esac

  echo "error: $flag must name a branch on origin as 'origin/<branch>' (got '$base'); a base must be provable as current against origin, and a tag, a raw commit, a revision expression, a local branch, or another remote's ref cannot be - pass the branch as 'origin/<branch>'" >&2
}

# The gate itself: accept a base or refuse it loudly. Returns non-zero on a
# refusal so a caller can exit on it.
fm_base_shape_check() {  # <base> [flag]
  fm_base_shape_ok "$1" && return 0
  fm_base_shape_refuse "$1" "${2:---base}"
  return 1
}
