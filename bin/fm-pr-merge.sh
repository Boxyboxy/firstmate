#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Red-PR refusal: AGENTS.md states "Never merge a red PR" as an absolute rule,
# so this path reads the PR's check state through `gh-axi pr checks` before
# merging and refuses when any check is failing, naming the failing checks.
# The three non-failing states are deliberately distinct from red:
#   - no checks configured at all is NOT red; several fleet repos have no
#     required checks, and blocking them would break ordinary merges.
#   - pending checks are NOT red; nothing has failed yet, so the merge proceeds
#     with a note on stderr rather than a refusal.
#   - a check state that cannot be read (the CLI failed, or its output carries
#     neither a summary nor the no-checks marker) IS a refusal: "not red" must
#     be a positive finding, never the absence of evidence.
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

# Read the PR's check state once. Sets CHECKS_OUT and returns 1 when the state
# could not be established at all (CLI failure, or output carrying neither a
# summary nor the no-checks marker).
read_check_state() {
  CHECKS_OUT=
  CHECKS_OUT=$(gh-axi pr checks "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null) || return 1
  case "$CHECKS_OUT" in
    *'no CI checks configured'*) return 0 ;;
    *'summary:'*) return 0 ;;
  esac
  return 1
}

# Echo one line per failing check name in CHECKS_OUT; no output means nothing
# is failing.
failing_checks() {
  printf '%s\n' "$CHECKS_OUT" | awk '
    /^checks\[[0-9]+\]\{name,conclusion\}:/ { in_list = 1; next }
    !in_list { next }
    /^  / {
      row = substr($0, 3)
      if (row !~ /,fail$/) next
      sub(/,fail$/, "", row)
      gsub(/^"|"$/, "", row)
      print row
      next
    }
    { in_list = 0 }
  '
}

# Count checks the forge has not concluded yet, so a merge over pending checks
# is reported rather than silent. Echoes 0 when the summary names no pending.
pending_check_count() {
  printf '%s\n' "$CHECKS_OUT" | awk '
    /^summary:/ {
      if (match($0, /[0-9]+ pending/)) {
        pending = substr($0, RSTART, RLENGTH)
        sub(/ pending/, "", pending)
        print pending + 0
        found = 1
      }
      exit
    }
    END { if (!found) print 0 }
  '
}

# Record a captain-authorized merge over a non-green check state in the task's
# meta. The override line is written above the canonical pr= block so the
# metadata identity parse in bin/fm-pr-lib.sh still accepts the file.
record_checks_override() {  # <reason>
  local reason=$1 tmp device
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || return 1
  {
    grep -vE '^(merge_checks_override|pr|pr_head)=' "$META" || true
    printf 'merge_checks_override=%s\n' "$reason"
    grep -E '^(pr|pr_head)=' "$META" || true
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$tmp" 600 "$device" || { rm -f -- "$tmp"; return 1; }
  fm_pr_metadata_identity_parse "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$META" || { rm -f -- "$tmp"; return 1; }
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
if read_check_state; then
  FAILING=$(failing_checks)
  if [ -n "$FAILING" ]; then
    if [ "$ALLOW_RED_CHECKS" = 0 ]; then
      echo "error: PR $URL has failing checks, refusing to merge:" >&2
      printf '%s\n' "$FAILING" | sed 's/^/  /' >&2
      echo "Fix the checks, or pass --allow-red-checks for a captain-authorized exception." >&2
      exit 1
    fi
    OVERRIDE_REASON="failing checks: $(printf '%s' "$FAILING" | tr '\n' ';' | sed 's/;$//;s/;/; /g')"
  fi
elif [ "$ALLOW_RED_CHECKS" = 0 ]; then
  echo "error: could not read the check state of PR $URL, refusing to merge; \"not red\" must be established, not assumed. Retry once gh-axi can reach the PR, or pass --allow-red-checks for a captain-authorized exception." >&2
  exit 1
else
  OVERRIDE_REASON="check state unreadable"
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

PENDING=$(pending_check_count)
if [ "$PENDING" -gt 0 ]; then
  echo "note: $PENDING check(s) on $URL are still pending; pending is not failing, so the merge proceeds" >&2
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
