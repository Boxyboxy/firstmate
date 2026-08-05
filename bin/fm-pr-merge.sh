#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to the forge CLIs as separate
# arguments, never as an interpolated URL.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, --method, or their short forms after the optional --
# separator. Extra args must not include --repo or -R because the repository
# comes only from the URL, nor --match-head-commit because the head comes only
# from the check state below, nor --admin because this path does not merge past
# the forge's own gates.
#
# Red-PR refusal: AGENTS.md states "Never merge a red PR" as an absolute rule,
# so this path reads the PR's check rollup as structured data through
# `gh pr view --json state,statusCheckRollup,headRefOid` - the same
# JSON-and-filter idiom bin/fm-pr-check.sh uses for its head reference - and
# classifies every entry
# here instead of consuming another tool's rendered pass/fail/pending summary.
# That rendering mapped a failing commit status, the shape external CI posts
# (a state rather than a conclusion), to pending, which is the one outcome this
# rule exists to prevent. Red is a conclusion of FAILURE, TIMED_OUT,
# ACTION_REQUIRED, STARTUP_FAILURE, or STALE, or a state of FAILURE or ERROR.
# The four non-failing states are deliberately distinct from red:
#   - no checks configured at all is NOT red; several fleet repos have no
#     required checks, and blocking them would break ordinary merges.
#   - pending checks are NOT red; nothing has failed yet, so the merge proceeds
#     with a note on stderr rather than a refusal. A required status context that
#     has been declared and has not reported yet (EXPECTED) is pending too.
#   - a rollup whose every check is skipped or cancelled is NOT red either;
#     skipped is a legitimate outcome of path filters and conditional jobs, so
#     refusing would block ordinary merges. It has nothing failing and nothing
#     pending, though, so it merges with its own note on stderr rather than
#     silently, the same treatment pending gets.
#   - a check state that cannot be read (the CLI failed, the rollup field is
#     absent or not an array, or fewer rows came back than the rollup's own
#     count) IS a refusal: "not red" must be a positive finding, never the
#     absence of evidence. The refusal carries whatever the CLI reported,
#     because an expired token, a missing scope, a rate limit, and a filter
#     error each need a different fix. A failing count with no extractable row
#     names refuses too, naming the count. A rollup that is both incomplete and
#     already red reports both facts, because "retry the CLI" is the wrong
#     action for a check that failed and an override recorded as unreadable
#     alone would lose the evidence that motivated it.
# The classification is only worth as much as the commit it describes, so the
# same read that returns the rollup returns the PR's headRefOid, and the merge is
# pinned to it with --match-head-commit. Reading the rollup and merging are
# seconds to minutes apart - bin/fm-pr-check.sh runs in between - and without the
# pin a commit pushed inside that window would land a head whose checks were
# never classified, which is the state this gate exists to prevent. The head is
# therefore part of the check state: a view that reports no usable head is
# unreadable like any other incomplete rollup, and the head the caller may not
# override, exactly as the repository comes only from the URL.
# A pin is only a pin if the forge evaluates it, so the merge is issued through
# `gh pr merge --match-head-commit`, which sends the head as a precondition
# GitHub itself enforces. The ergonomic gh-axi wrapper builds its gh argv from a
# fixed flag allowlist and passes nothing else through, so a pin handed to it
# would be dropped without a word and every guarantee below would be theatre.
# gh is already this path's hard dependency for the rollup read above, so the
# merge uses the one CLI that can enforce what was classified. gh spells the
# merge method as a shorthand flag and has no --method, so a caller that names
# one is translated rather than silently losing its choice, and it honours the
# short forms the wrapper used to discard, so those count as an explicit method
# too. The same read reports where the PR itself stands, because a PR that has
# already landed must not be merged a second time: a retry after a merge whose
# report was lost records the metadata and reports the landing rather than
# failing, which is the wrapper's idempotence kept rather than lost with it.
# --allow-red-checks is the captain-authorized exception. It merges anyway and
# records merge_checks_override=<reason> in the task's meta before the merge, so
# the decision stays durable. The record is written above the canonical pr= line
# because bin/fm-pr-lib.sh's metadata identity parse rejects unknown keys after it.
# The record is reconciled, not only written: a later clean merge clears a record
# left by an earlier authorized attempt, so the metadata describes the merge that
# actually happened rather than an override that no longer applies.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red-checks]
#                       [-- <extra gh pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
ALLOW_RED_CHECKS=0
if [ "${1:-}" = "--allow-red-checks" ]; then
  ALLOW_RED_CHECKS=1
  shift
fi
[ "${1:-}" = "--" ] && shift

# gh takes -s, -m, and -r as the merge methods' short forms and honours them, so
# a caller that spells one that way has chosen a method just as explicitly as the
# long form; missing them would add a second, conflicting default.
caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
      -s|-m|-r) return 0 ;;
    esac
  done
  return 1
}

# The repository comes only from the URL and the head commit comes only from the
# check state this merge classified, so neither may be supplied by the caller.
# --admin joins them because "never merge a red PR" leans on the forge's own
# required-check and review gates as its backstop, and administrator merge is
# exactly the flag that lands a PR past them. The classification above already
# refuses red before any CLI runs, so this removes no protection the caller had;
# it makes an argument that never reached the forge an explicit refusal.
reject_derived_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the head commit; it comes only from the check state this merge classified" >&2
        return 1
        ;;
      --admin)
        echo "error: extra merge arguments must not include --admin; merging past the forge's own required checks and reviews is not something this guarded path does" >&2
        return 1
        ;;
    esac
  done
}

reject_derived_overrides "$@" || exit 1

# Rewrite a caller's --method <m> into the shorthand flag gh understands. The
# value is checked against the three methods that exist, because an unchecked one
# would become an arbitrary flag on the merge command line - including the very
# flags rejected just above.
normalize_merge_method() {
  local method
  MERGE_ARGV=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method|--method=*)
        if [ "$1" = --method ]; then
          [ "$#" -ge 2 ] || {
            echo "error: --method requires one of merge, squash, or rebase" >&2
            return 1
          }
          method=$2
          shift 2
        else
          method=${1#--method=}
          shift
        fi
        case "$method" in
          merge|squash|rebase) ;;
          *)
            echo "error: --method must be one of merge, squash, or rebase" >&2
            return 1
            ;;
        esac
        MERGE_ARGV+=("--$method")
        ;;
      *)
        MERGE_ARGV+=("$1")
        shift
        ;;
    esac
  done
}

normalize_merge_method "$@" || exit 1
set -- "${MERGE_ARGV[@]+"${MERGE_ARGV[@]}"}"

# An interrupt between mktemp and mv must not leave a private temp file behind,
# the same reason bin/fm-pr-check.sh traps its own meta temp.
MERGE_META_TMP=
GH_ERR_FILE=
pr_merge_cleanup() {
  [ -z "$MERGE_META_TMP" ] || rm -f -- "$MERGE_META_TMP"
  [ -z "$GH_ERR_FILE" ] || rm -f -- "$GH_ERR_FILE"
}
trap pr_merge_cleanup EXIT
trap 'exit 1' HUP INT TERM

# The rollup is asked for as data, not prose: a "state|<state>" header naming
# where the PR itself stands, a "head|<sha>" header naming the commit the rollup
# describes, a "rollup|<count>" header the forge itself counts, then one
# "<conclusion>|<state>|<name>" row per entry. The name is last so a name
# containing the separator still parses, and conclusion and state are forge enums
# that cannot contain one. The head comes from this same read so it is the head
# the rollup was computed for, not whatever the branch points at by the time the
# merge runs. A missing or non-array rollup field errors out of the filter, so a
# read that cannot see the rollup fails instead of looking green and empty.
CHECK_ROLLUP_FILTER='"state|\(.state // "")", "head|\(.headRefOid // "")", (if (.statusCheckRollup | type) == "array" then (.statusCheckRollup | "rollup|\(length)", (.[] | [(.conclusion // ""), (.state // ""), ((.name // .context // "") | gsub("[\n\r]"; " "))] | join("|"))) else error("statusCheckRollup is missing from the PR view") end)'

# Collapse whatever the CLI wrote to stderr into one bounded line. An expired
# token, a missing scope, a rate limit, and a filter error each need a different
# operator action, and this is the only evidence that distinguishes them, so it
# is carried into the refusal rather than discarded.
gh_error_detail() {
  local detail
  [ -n "$GH_ERR_FILE" ] && [ -f "$GH_ERR_FILE" ] || return 0
  detail=$(tr '\n\r\t' '   ' < "$GH_ERR_FILE" | sed 's/  */ /g; s/^ //; s/ *$//') || return 0
  [ -n "$detail" ] || return 0
  [ "${#detail}" -le 400 ] || detail="${detail:0:400}..."
  printf '%s' "$detail"
}

# Read the PR's check rollup once. Sets PR_STATE to where the PR itself stands,
# CHECK_HEAD to the head commit the rollup describes, CHECK_TOTAL to the count
# the forge reports and CHECK_ROWS to its rows, and returns 1 when the state
# could not be established at all (CLI failure, or output that does not carry the
# headers), leaving CHECK_READ_DETAIL naming the cause.
read_check_state() {
  local out header
  CHECK_ROWS=
  CHECK_TOTAL=0
  CHECK_HEAD=
  PR_STATE=
  CHECK_READ_DETAIL=
  GH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh.XXXXXX") || {
    CHECK_READ_DETAIL="the CLI's diagnostics could not be captured"
    return 1
  }
  out=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json state,statusCheckRollup,headRefOid -q "$CHECK_ROLLUP_FILTER" 2>"$GH_ERR_FILE") || {
    CHECK_READ_DETAIL=$(gh_error_detail)
    [ -n "$CHECK_READ_DETAIL" ] || CHECK_READ_DETAIL="the CLI failed without reporting a reason"
    return 1
  }
  header=${out%%$'\n'*}
  case "$header" in
    "state|"*) PR_STATE=${header#state|} ;;
    *)
      CHECK_READ_DETAIL="the rollup query returned no PR state header"
      return 1
      ;;
  esac
  [ "$out" != "$header" ] || {
    CHECK_READ_DETAIL="the rollup query returned no usable header"
    return 1
  }
  out=${out#*$'\n'}
  header=${out%%$'\n'*}
  case "$header" in
    "head|"*) CHECK_HEAD=${header#head|} ;;
    *)
      CHECK_READ_DETAIL="the rollup query returned no head header"
      return 1
      ;;
  esac
  [ "$out" != "$header" ] || {
    CHECK_READ_DETAIL="the rollup query returned no usable header"
    return 1
  }
  out=${out#*$'\n'}
  header=${out%%$'\n'*}
  case "$header" in
    "rollup|"*) CHECK_TOTAL=${header#rollup|} ;;
    *)
      CHECK_READ_DETAIL="the rollup query returned no usable header"
      return 1
      ;;
  esac
  case "$CHECK_TOTAL" in
    ''|*[!0-9]*)
      CHECK_READ_DETAIL="the rollup reported a non-numeric check count"
      return 1
      ;;
  esac
  if [ "$CHECK_TOTAL" -gt 0 ]; then
    [ "$out" != "$header" ] || {
      CHECK_READ_DETAIL="the rollup counts $CHECK_TOTAL check(s) but returned no rows"
      return 1
    }
    CHECK_ROWS=${out#*$'\n'}
  fi
  return 0
}

# Classify one rollup entry from the raw values the forge reports. Check runs
# carry a conclusion and commit statuses carry a state, so both are consulted:
# reading only one of them is what let a failing external check pass as pending.
classify_check() {  # <conclusion> <state>
  case "$1" in
    FAILURE|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE|STALE) printf 'fail\n'; return 0 ;;
    SUCCESS) printf 'pass\n'; return 0 ;;
    SKIPPED|CANCELLED|NEUTRAL) printf 'skip\n'; return 0 ;;
  esac
  # NEUTRAL is a check-run conclusion and never a status state, so it has no arm
  # here. EXPECTED is a required status context that has been declared and has
  # not reported yet, which is pending rather than skipped: classifying it as
  # skipped would leave a rollup that is neither all-skipped nor pending, and so
  # merge with no note at all.
  case "$2" in
    FAILURE|ERROR) printf 'fail\n'; return 0 ;;
    SUCCESS) printf 'pass\n'; return 0 ;;
    SKIPPED|CANCELLED) printf 'skip\n'; return 0 ;;
  esac
  printf 'pending\n'
}

# Tally CHECK_ROWS into the per-class counts the gate decides on, collecting the
# failing rows' names. Only a well-formed row is counted, and CHECK_SEEN is
# compared against the forge's own CHECK_TOTAL, so a rollup whose rows could not
# be extracted is unreadable rather than silently green.
tally_check_rows() {
  local line name conclusion state rest class
  CHECK_SEEN=0
  CHECK_FAIL=0
  CHECK_PENDING=0
  CHECK_SKIP=0
  FAILING=
  [ -n "$CHECK_ROWS" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *'|'*'|'*) ;;
      *) continue ;;
    esac
    conclusion=${line%%'|'*}
    rest=${line#*'|'}
    state=${rest%%'|'*}
    name=${rest#*'|'}
    CHECK_SEEN=$((CHECK_SEEN + 1))
    class=$(classify_check "$conclusion" "$state")
    case "$class" in
      fail)
        CHECK_FAIL=$((CHECK_FAIL + 1))
        if [ -n "$name" ]; then
          FAILING="$FAILING$name"$'\n'
        fi
        ;;
      pending) CHECK_PENDING=$((CHECK_PENDING + 1)) ;;
      skip) CHECK_SKIP=$((CHECK_SKIP + 1)) ;;
    esac
  done <<EOF
$CHECK_ROWS
EOF
}

# Collapse the failing rows that were read into one line, for the refusal the
# operator acts on and for the durable override record alike. A rollup that was
# only partly readable can still have named failing checks, and those names are
# the actionable fact in both places.
failing_summary() {
  if [ -n "$FAILING" ]; then
    printf '%s' "$FAILING" | tr '\n' ';' | sed 's/;$//;s/;/; /g'
  else
    printf '%s unnamed' "$CHECK_FAIL"
  fi
}

# Reconcile the task's meta with the check state this merge actually acted on: a
# non-empty reason records the captain-authorized merge over a non-green state,
# and an empty reason clears whatever an earlier authorized attempt recorded, so
# a later clean merge does not inherit an override it never used. Any prior
# record is stripped either way. The override line is written above the canonical
# pr= block so the metadata identity parse in bin/fm-pr-lib.sh still accepts the
# file.
#
# This is bin/fm-pr-check.sh's meta write, on the identical file, so it is that
# writer's reconstruction and its whole guard set rather than a lookalike: a
# single read of the file that fails loudly instead of a filter whose partial
# output would still parse clean while dropping window=, worktree=, project=,
# harness=, and mode= (which teardown's landed-work check and the watcher read);
# device parity, so the replace is a rename and not a copy; and validation of
# the destination after the replace, not only of the temp file before it.
record_checks_override() {  # <reason>  (empty clears any prior record)
  local reason=$1 line pr_block='' meta_device state_device
  # A newline in the reason would inject arbitrary keys above the pr= line,
  # where the identity parse does not reject them.
  case "$reason" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  meta_device=$(fm_pr_file_device "$META") || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  [ "$meta_device" = "$state_device" ] || return 1
  MERGE_META_TMP=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      merge_checks_override=*) ;;
      pr=*|pr_head=*) pr_block="$pr_block$line"$'\n' ;;
      *) printf '%s\n' "$line" >> "$MERGE_META_TMP" || return 1 ;;
    esac
  done < "$META" || return 1
  [ -z "$reason" ] \
    || printf 'merge_checks_override=%s\n' "$reason" >> "$MERGE_META_TMP" || return 1
  printf '%s' "$pr_block" >> "$MERGE_META_TMP" || return 1
  chmod 0600 "$MERGE_META_TMP" || return 1
  fm_pr_private_file_valid "$MERGE_META_TMP" 600 "$state_device" || return 1
  fm_pr_metadata_identity_parse "$MERGE_META_TMP" || return 1
  [ "$FM_PR_META_URL" = "$URL" ] || return 1
  # Re-establish the destination's shape immediately before the atomic replace,
  # exactly as bin/fm-pr-check.sh does for its own meta write.
  fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || return 1
  mv -f -- "$MERGE_META_TMP" "$META" || return 1
  MERGE_META_TMP=
  fm_pr_private_file_valid "$META" 600 "$state_device" || return 1
  fm_pr_metadata_identity_parse "$META" || return 1
  [ "$FM_PR_META_URL" = "$URL" ]
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Never merge a red PR (AGENTS.md). Read the check state before any state is
# recorded or any poll is armed, so a refusal leaves nothing behind.
OVERRIDE_REASON=
CHECK_TOTAL=0
CHECK_SEEN=0
CHECK_FAIL=0
CHECK_PENDING=0
CHECK_SKIP=0
CHECK_HEAD=
PR_STATE=
FAILING=
UNREADABLE=
CHECK_READ_DETAIL=
if read_check_state; then
  tally_check_rows
  if [ "$CHECK_SEEN" -ne "$CHECK_TOTAL" ]; then
    UNREADABLE="the rollup counts $CHECK_TOTAL check(s) but only $CHECK_SEEN row(s) could be read"
  fi
  # A rollup with no head to attach it to establishes nothing that survives to
  # merge time, so it is incomplete in exactly the way a short row list is.
  if ! fm_pr_head_valid "$CHECK_HEAD"; then
    CHECK_HEAD=
    if [ -n "$UNREADABLE" ]; then
      UNREADABLE="$UNREADABLE, and the PR view reported no usable head commit to pin the merge to"
    else
      UNREADABLE="the PR view reported no usable head commit to pin the merge to"
    fi
  fi
else
  UNREADABLE="gh could not return the PR's check rollup"
  [ -z "$CHECK_READ_DETAIL" ] || UNREADABLE="$UNREADABLE: $CHECK_READ_DETAIL"
fi

if [ -n "$UNREADABLE" ]; then
  # A partly-read rollup can be unreadable AND already red. Both facts are
  # reported, because "retry once gh can reach the PR" is the wrong action when
  # the rows that did come back name failing checks, and an override recorded
  # only as "unreadable" loses the evidence that motivated it.
  if [ "$CHECK_FAIL" -gt 0 ]; then
    UNREADABLE="$UNREADABLE, and the rows that were read name failing checks: $(failing_summary)"
  fi
  if [ "$ALLOW_RED_CHECKS" = 0 ]; then
    echo "error: could not read the check state of PR $URL ($UNREADABLE), refusing to merge; \"not red\" must be established, not assumed." >&2
    if [ "$CHECK_FAIL" -gt 0 ]; then
      echo "Fix those checks and retry once gh can read the whole rollup, or pass --allow-red-checks for a captain-authorized exception." >&2
    else
      echo "Retry once gh can reach the PR, or pass --allow-red-checks for a captain-authorized exception." >&2
    fi
    exit 1
  fi
  OVERRIDE_REASON="check state unreadable: $UNREADABLE"
elif [ "$CHECK_FAIL" -gt 0 ]; then
  if [ "$ALLOW_RED_CHECKS" = 0 ]; then
    echo "error: PR $URL has failing checks, refusing to merge:" >&2
    if [ -n "$FAILING" ]; then
      printf '%s' "$FAILING" | sed 's/^/  /' >&2
    else
      echo "  $CHECK_FAIL failing check(s), none of which the rollup named" >&2
    fi
    echo "Fix the checks, or pass --allow-red-checks for a captain-authorized exception." >&2
    exit 1
  fi
  OVERRIDE_REASON="failing checks: $(failing_summary)"
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# A PR that already landed has nothing left to merge, and this path is re-run
# exactly when a merge succeeded but its report did not survive. Recording the
# metadata is still the job, so that happens above and the merge itself is left
# alone. Any override record stays untouched: the authorized merge it describes
# may be the one that landed, and reconciling it away here would erase a true
# record of how this PR reached the base branch.
if [ "$PR_STATE" = MERGED ]; then
  echo "note: PR $URL is already merged; recorded its metadata and left the merge alone" >&2
  exit 0
fi

# Durably record the authorized exception before merging, so the decision
# survives even if the merge itself is interrupted. A merge that needs no
# exception still rewrites the meta when an earlier attempt left one behind: that
# earlier merge may well have failed after recording, and a record that outlives
# the state it describes asserts an authorization this merge never used.
if [ -n "$OVERRIDE_REASON" ] || grep -q '^merge_checks_override=' "$META"; then
  record_checks_override "$OVERRIDE_REASON" || {
    if [ -n "$OVERRIDE_REASON" ]; then
      echo "error: could not record the authorized check-state override in task metadata; refusing to merge" >&2
    else
      echo "error: could not clear a stale check-state override from task metadata; refusing to merge" >&2
    fi
    exit 1
  }
fi

if [ "$CHECK_PENDING" -gt 0 ]; then
  echo "note: $CHECK_PENDING check(s) on $URL are still pending; pending is not failing, so the merge proceeds" >&2
fi

# A rollup whose every check is skipped or cancelled has nothing failing and
# nothing pending, so it would otherwise merge with no evidence at all. Skipped
# is a legitimate outcome of path filters and conditional jobs, so it is not
# red, but the merge says so out loud.
if [ "$CHECK_TOTAL" -gt 0 ] && [ "$CHECK_SKIP" -eq "$CHECK_TOTAL" ]; then
  echo "note: all $CHECK_TOTAL check(s) on $URL are skipped or cancelled, so no check actually passed; skipped is not failing, so the merge proceeds" >&2
fi

# Pin the merge to the head the rollup above was computed for. bin/fm-pr-check.sh
# ran in between, so a commit pushed since that read would otherwise land
# unclassified; the forge refuses the merge instead. The only way to reach here
# without a head is an authorized exception over a state that could not be read,
# where there is no classified head to pin to, and that says so out loud.
merge_args=()
if [ -n "$CHECK_HEAD" ]; then
  merge_args+=(--match-head-commit "$CHECK_HEAD")
else
  echo "note: no head commit could be read for $URL, so this authorized merge is not pinned to the head whose checks were classified" >&2
fi
if ! caller_has_merge_method "$@"; then
  merge_args+=(--squash)
fi

gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
