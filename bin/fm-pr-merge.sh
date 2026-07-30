#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to the forge CLIs as separate
# arguments, never as an interpolated URL.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Red-PR refusal: AGENTS.md states "Never merge a red PR" as an absolute rule,
# so this path reads the PR's check rollup as structured data through
# `gh pr view --json statusCheckRollup` - the same JSON-and-filter idiom
# bin/fm-pr-check.sh uses for its head reference - and classifies every entry
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
#     names refuses too, naming the count.
# --allow-red-checks is the captain-authorized exception. It merges anyway and
# records merge_checks_override=<reason> in the task's meta before the merge, so
# the decision stays durable. The record is written above the canonical pr= line
# because bin/fm-pr-lib.sh's metadata identity parse rejects unknown keys after it.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red-checks]
#                       [-- <extra gh-axi pr merge args>]
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

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

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

# The rollup is asked for as data, not prose: a "rollup|<count>" header the forge
# itself counts, then one "<conclusion>|<state>|<name>" row per entry. The name
# is last so a name containing the separator still parses, and conclusion and
# state are forge enums that cannot contain one. A missing or non-array rollup
# field errors out of the filter, so a read that cannot see the rollup fails
# instead of looking green and empty.
CHECK_ROLLUP_FILTER='if (.statusCheckRollup | type) == "array" then (.statusCheckRollup | "rollup|\(length)", (.[] | [(.conclusion // ""), (.state // ""), ((.name // .context // "") | gsub("[\n\r]"; " "))] | join("|"))) else error("statusCheckRollup is missing from the PR view") end'

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

# Read the PR's check rollup once. Sets CHECK_TOTAL to the count the forge
# reports and CHECK_ROWS to its rows, and returns 1 when the state could not be
# established at all (CLI failure, or output that does not carry the header),
# leaving CHECK_READ_DETAIL naming the cause.
read_check_state() {
  local out header
  CHECK_ROWS=
  CHECK_TOTAL=0
  CHECK_READ_DETAIL=
  GH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh.XXXXXX") || {
    CHECK_READ_DETAIL="the CLI's diagnostics could not be captured"
    return 1
  }
  out=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json statusCheckRollup -q "$CHECK_ROLLUP_FILTER" 2>"$GH_ERR_FILE") || {
    CHECK_READ_DETAIL=$(gh_error_detail)
    [ -n "$CHECK_READ_DETAIL" ] || CHECK_READ_DETAIL="the CLI failed without reporting a reason"
    return 1
  }
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

# Record a captain-authorized merge over a non-green check state in the task's
# meta. The override line is written above the canonical pr= block so the
# metadata identity parse in bin/fm-pr-lib.sh still accepts the file.
#
# This is bin/fm-pr-check.sh's meta write, on the identical file, so it is that
# writer's reconstruction and its whole guard set rather than a lookalike: a
# single read of the file that fails loudly instead of a filter whose partial
# output would still parse clean while dropping window=, worktree=, project=,
# harness=, and mode= (which teardown's landed-work check and the watcher read);
# device parity, so the replace is a rename and not a copy; and validation of
# the destination after the replace, not only of the temp file before it.
record_checks_override() {  # <reason>
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
  printf 'merge_checks_override=%s\n' "$reason" >> "$MERGE_META_TMP" || return 1
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
FAILING=
UNREADABLE=
CHECK_READ_DETAIL=
if read_check_state; then
  tally_check_rows
  if [ "$CHECK_SEEN" -ne "$CHECK_TOTAL" ]; then
    UNREADABLE="the rollup counts $CHECK_TOTAL check(s) but only $CHECK_SEEN row(s) could be read"
  fi
else
  UNREADABLE="gh could not return the PR's check rollup"
  [ -z "$CHECK_READ_DETAIL" ] || UNREADABLE="$UNREADABLE: $CHECK_READ_DETAIL"
fi

if [ -n "$UNREADABLE" ]; then
  if [ "$ALLOW_RED_CHECKS" = 0 ]; then
    echo "error: could not read the check state of PR $URL ($UNREADABLE), refusing to merge; \"not red\" must be established, not assumed. Retry once gh can reach the PR, or pass --allow-red-checks for a captain-authorized exception." >&2
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
  if [ -n "$FAILING" ]; then
    OVERRIDE_REASON="failing checks: $(printf '%s' "$FAILING" | tr '\n' ';' | sed 's/;$//;s/;/; /g')"
  else
    OVERRIDE_REASON="failing checks: $CHECK_FAIL unnamed"
  fi
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Durably record the authorized exception before merging, so the decision
# survives even if the merge itself is interrupted.
if [ -n "$OVERRIDE_REASON" ]; then
  record_checks_override "$OVERRIDE_REASON" || {
    echo "error: could not record the authorized check-state override in task metadata; refusing to merge" >&2
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

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
