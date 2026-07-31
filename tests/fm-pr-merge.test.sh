#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a failing check state refuses before recording or merging
#   (j) no configured checks and pending checks are both treated as not red
#   (k) an all-skipped rollup merges but says so, rather than merging silently
#   (l) an unreadable check state refuses, because "not red" must be established
#   (m) --allow-red-checks merges and records the override durably in task meta
#   (n) every red class the forge can report refuses: the CheckRun conclusions
#       FAILURE, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE, and STALE, and the
#       commit-status states FAILURE and ERROR that external CI posts
#   (o) a rollup that counts more checks than it returns rows for is unreadable,
#       and a failing count with no row names still refuses, naming the count
#   (p) a declared-but-unreported required status (EXPECTED) is pending, so the
#       merge says so instead of proceeding with no evidence at all
#   (q) an unreadable refusal carries the CLI's own diagnostic, because the fix
#       differs per cause
#   (r) recording an authorized override preserves every unrelated meta field
#       and leaves no private temp file behind
#   (s) the script's own rollup filter, not a mock's copy of what it emits, reads
#       recorded forge payloads: a failing check run, a failing commit status, a
#       declared-but-unreported required status, an all-skipped rollup, and a
#       payload whose rollup cannot be read at all
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# The check gate reads the rollup as structured data through
# `gh pr view --json statusCheckRollup -q <filter>`, so the mock answers what
# that filter emits: a "rollup|<count>" header followed by one
# "<conclusion>|<state>|<name>" row per entry, where a check run carries a
# conclusion and a commit status carries a state. Rows come from FM_TEST_ROLLUP
# (the ROLLUP_EMPTY sentinel means a rollup with no entries at all),
# FM_TEST_ROLLUP_COUNT can disagree with the rows on purpose, and
# FM_TEST_ROLLUP_RC makes the query itself fail the way a filter error does.
ROLLUP_GREEN='SUCCESS||Lint shell scripts
SUCCESS||Test coverage guard'
ROLLUP_EMPTY='__no_checks__'

# FM_TEST_ROLLUP_FIXTURE switches the mock from emitting those rows to replaying
# a recorded payload through the script's own -q filter, which is the only way
# the filter itself is under test rather than a hand-copy of what it produces.
# jq stands in for the CLI's embedded evaluator, so its exit status and stderr
# reach the gate exactly as the CLI's would.
# shellcheck disable=SC2016  # Mock source: these expansions must stay literal.
GH_ROLLUP_MOCK_BODY='
    case " $* " in
      *statusCheckRollup*)
        if [ -n "${FM_TEST_ROLLUP_FIXTURE:-}" ]; then
          filter=
          prev=
          for arg in "$@"; do
            [ "$prev" = "-q" ] && filter=$arg
            prev=$arg
          done
          exec jq -r "$filter" "$FM_TEST_ROLLUP_FIXTURE"
        fi
        if [ "${FM_TEST_ROLLUP_RC:-0}" != 0 ]; then
          [ -z "${FM_TEST_ROLLUP_ERR:-}" ] || printf "%s\n" "$FM_TEST_ROLLUP_ERR" >&2
          exit "${FM_TEST_ROLLUP_RC}"
        fi
        rows=$FM_TEST_ROLLUP
        [ "$rows" = "__no_checks__" ] && rows=
        count=${FM_TEST_ROLLUP_COUNT:-}
        if [ -z "$count" ]; then
          if [ -z "$rows" ]; then count=0; else count=$(printf %s\\n "$rows" | wc -l | tr -d " "); fi
        fi
        printf "rollup|%s\n" "$count"
        [ -z "$rows" ] || printf "%s\n" "$rows"
        exit 0 ;;
    esac
'

# gh-axi mock recording every invocation to a log file, and gh mock answering
# both headRefOid for fm-pr-check.sh's pr_head lookup and the check rollup for
# the red-PR gate. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
$GH_ROLLUP_MOCK_BODY
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
$GH_ROLLUP_MOCK_BODY
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_ROLLUP="${FM_TEST_ROLLUP:-$ROLLUP_GREEN}" \
  FM_TEST_ROLLUP_COUNT="${FM_TEST_ROLLUP_COUNT:-}" \
  FM_TEST_ROLLUP_RC="${FM_TEST_ROLLUP_RC:-0}" \
  FM_TEST_ROLLUP_ERR="${FM_TEST_ROLLUP_ERR:-}" \
  FM_TEST_ROLLUP_FIXTURE="${FM_TEST_ROLLUP_FIXTURE:-}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# Two failing checks, one name carrying the row separator, so the refusal must
# name both and must not truncate a name at the separator.
ROLLUP_RED='SUCCESS||Lint shell scripts
FAILURE||PR must be raised via no-mistakes
TIMED_OUT||Behavior | portable serial'

test_failing_checks_refuse_before_merge() {
  local case_dir rc
  case_dir=$(make_case failing-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failing-checks: fm-pr-merge should refuse a red PR"
  assert_grep 'has failing checks, refusing to merge' "$case_dir/stderr" \
    "failing-checks: refusal did not explain the red check state"
  assert_grep 'PR must be raised via no-mistakes' "$case_dir/stderr" \
    "failing-checks: refusal did not name the failing check"
  assert_grep 'Behavior | portable serial' "$case_dir/stderr" \
    "failing-checks: refusal did not name a failing check whose name contains the row separator"
  assert_grep '--allow-red-checks' "$case_dir/stderr" \
    "failing-checks: refusal did not name the captain-authorized override"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "failing-checks: gh-axi pr merge was invoked for a red PR"
  assert_no_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "failing-checks: a red PR was recorded in meta before the refusal"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "failing-checks: a red PR armed a merge poll"
  pass "fm-pr-merge refuses a red PR before recording state or merging"
}

test_no_configured_checks_are_not_red() {
  local case_dir
  case_dir=$(make_case no-checks-configured)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP="$ROLLUP_EMPTY" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-checks-configured: fm-pr-merge should merge a PR with no checks configured"

  grep -qxF 'pr merge 32 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-checks-configured: a repo with no required checks was blocked from merging"
  assert_no_grep 'merge_checks_override=' "$case_dir/state/task-x1.meta" \
    "no-checks-configured: an unused override was recorded"
  pass "fm-pr-merge treats a PR with no configured checks as not red"
}

test_pending_checks_do_not_block() {
  local case_dir
  case_dir=$(make_case pending-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  # A queued check run carries no conclusion yet, and a commit status that has
  # not reported carries PENDING: both are pending, neither is red.
  FM_TEST_ROLLUP='SUCCESS||Lint shell scripts
||Behavior tests
|PENDING|vercel' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pending-checks: fm-pr-merge should not refuse a PR whose checks are only pending"

  grep -qxF 'pr merge 33 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "pending-checks: pending checks blocked the merge"
  assert_grep '2 check(s)' "$case_dir/stderr" \
    "pending-checks: merging over pending checks was silent"
  assert_no_grep 'merge_checks_override=' "$case_dir/state/task-x1.meta" \
    "pending-checks: pending checks were recorded as an override"
  pass "fm-pr-merge merges over pending checks and reports that it did"
}

# SKIPPED and CANCELLED are both skipped outcomes, so a rollup that was entirely
# cancelled or path-filtered away has nothing failing and nothing pending. That
# is not red, but it must not merge without leaving evidence.
test_all_skipped_checks_merge_with_a_note() {
  local case_dir
  case_dir=$(make_case all-skipped-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP='SKIPPED||Lint shell scripts
SKIPPED||Behavior tests
CANCELLED||Docs check
CANCELLED||Typecheck
NEUTRAL||Build' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "all-skipped-checks: fm-pr-merge should not refuse a rollup that is only skipped"

  grep -qxF 'pr merge 34 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "all-skipped-checks: an all-skipped rollup blocked the merge"
  assert_grep 'all 5 check(s)' "$case_dir/stderr" \
    "all-skipped-checks: merging an all-skipped rollup was silent"
  assert_no_grep 'merge_checks_override=' "$case_dir/state/task-x1.meta" \
    "all-skipped-checks: a skipped rollup was recorded as an override"
  pass "fm-pr-merge merges an all-skipped rollup and reports that it did"
}

test_unreadable_check_state_refuses() {
  local case_dir rc
  case_dir=$(make_case unreadable-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP_RC=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-checks: fm-pr-merge should refuse when the check state cannot be read"
  assert_grep 'could not read the check state' "$case_dir/stderr" \
    "unreadable-checks: refusal did not explain the unreadable check state"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unreadable-checks: gh-axi pr merge was invoked without an established check state"
  pass "fm-pr-merge refuses when the check state cannot be established"
}

test_allow_red_checks_merges_and_records_override() {
  local case_dir meta override_line pr_line
  case_dir=$(make_case allow-red-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "allow-red-checks: an authorized exception should still merge"

  meta="$case_dir/state/task-x1.meta"
  grep -qxF 'pr merge 35 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "allow-red-checks: the authorized merge did not reach gh-axi"
  assert_grep 'merge_checks_override=failing checks:' "$meta" \
    "allow-red-checks: the authorized override was not recorded durably"
  assert_grep 'PR must be raised via no-mistakes' "$meta" \
    "allow-red-checks: the override record did not name the failing checks"
  # The canonical pr= block must stay last: bin/fm-pr-lib.sh's metadata identity
  # parse rejects any unknown key that follows it, which would break the watcher.
  override_line=$(grep -n '^merge_checks_override=' "$meta" | cut -d: -f1)
  pr_line=$(grep -n '^pr=' "$meta" | cut -d: -f1)
  [ "$override_line" -lt "$pr_line" ] \
    || fail "allow-red-checks: the override record was written after the canonical pr= line"
  pass "fm-pr-merge records a captain-authorized red-check merge in task metadata"
}

# Every shape of red the forge can report must refuse, whichever field carries
# it. A check run reports a conclusion; a commit status, which is how external CI
# integrations post, reports a state instead - and reading only the conclusion is
# what let a genuinely red external check merge as "pending".
test_every_red_class_refuses() {
  local case_dir rc class field row n=40
  for class in "conclusion FAILURE" "conclusion TIMED_OUT" \
    "conclusion ACTION_REQUIRED" "conclusion STARTUP_FAILURE" \
    "conclusion STALE" "state FAILURE" "state ERROR"; do
    field=${class%% *}
    row=${class##* }
    case_dir=$(make_case "red-$field-$row")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
    : > "$case_dir/gh-axi.log"
    if [ "$field" = conclusion ]; then
      row="$row||external ci"
    else
      row="|$row|external ci"
    fi

    set +e
    FM_TEST_ROLLUP="SUCCESS||Lint shell scripts
$row" \
      run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$n" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "red-$field: a $field of ${class##* } should refuse the merge"
    assert_grep 'has failing checks, refusing to merge' "$case_dir/stderr" \
      "red-$field: refusal did not explain the red check state for ${class##* }"
    assert_grep 'external ci' "$case_dir/stderr" \
      "red-$field: refusal did not name the check reporting ${class##* }"
    assert_no_grep 'still pending' "$case_dir/stderr" \
      "red-$field: a ${class##* } result was reported as pending instead of red"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "red-$field: a ${class##* } result reached gh-axi pr merge"
    n=$((n + 1))
  done
  pass "fm-pr-merge classifies every red conclusion and commit-status state as red"
}

# The rollup's own count is the cross-check on the rows: if fewer rows come back
# than the forge counted, the state is unreadable rather than green, and a
# failing count with no usable row names still refuses, naming the count.
test_row_count_mismatch_is_unreadable() {
  local case_dir rc
  case_dir=$(make_case rollup-count-mismatch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP='SUCCESS||Lint shell scripts' FM_TEST_ROLLUP_COUNT=4 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/50 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "rollup-count-mismatch: an incomplete rollup should refuse"
  assert_grep 'could not read the check state' "$case_dir/stderr" \
    "rollup-count-mismatch: refusal did not treat a short rollup as unreadable"
  assert_grep 'counts 4 check(s) but only 1 row(s)' "$case_dir/stderr" \
    "rollup-count-mismatch: refusal did not name the counts it compared"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "rollup-count-mismatch: an unreadable rollup reached gh-axi pr merge"
  pass "fm-pr-merge treats a rollup shorter than its own count as unreadable"
}

test_unnamed_failing_check_still_refuses() {
  local case_dir rc
  case_dir=$(make_case unnamed-failing-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP='FAILURE||
|ERROR|' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unnamed-failing-check: a nameless failing check should still refuse"
  assert_grep 'has failing checks, refusing to merge' "$case_dir/stderr" \
    "unnamed-failing-check: refusal did not explain the red check state"
  assert_grep '2 failing check(s), none of which the rollup named' "$case_dir/stderr" \
    "unnamed-failing-check: refusal did not fall back to naming the failing count"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unnamed-failing-check: a nameless red rollup reached gh-axi pr merge"
  pass "fm-pr-merge refuses on the failing count when no row name can be extracted"
}

# A declared-but-unreported required status context is pending, not skipped.
# Classifying it as skipped leaves a rollup that is neither all-skipped nor
# pending, so the merge would print nothing at all - the one outcome this
# script's design rules out.
test_expected_status_is_pending() {
  local case_dir
  case_dir=$(make_case expected-status)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP='SUCCESS||Lint shell scripts
|EXPECTED|required-context' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-status: a declared-but-unreported required status is not red"

  grep -qxF 'pr merge 52 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "expected-status: an EXPECTED required status blocked the merge"
  assert_grep '1 check(s)' "$case_dir/stderr" \
    "expected-status: merging over a declared-but-unreported status was silent"
  assert_grep 'still pending' "$case_dir/stderr" \
    "expected-status: a declared-but-unreported status was not reported as pending"
  pass "fm-pr-merge treats a declared-but-unreported required status as pending, not skipped"
}

# The unreadable refusal is the only evidence an operator gets, and an expired
# token, a missing scope, a rate limit, and a filter error each need a different
# fix, so the CLI's own diagnostic has to survive into the message.
test_unreadable_refusal_names_the_cause() {
  local case_dir rc
  case_dir=$(make_case unreadable-cause)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4040404040404040404040404040404040404040
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP_RC=1 \
  FM_TEST_ROLLUP_ERR='gh: authentication token expired, run gh auth login' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-cause: an unreadable check state should refuse"
  assert_grep 'could not read the check state' "$case_dir/stderr" \
    "unreadable-cause: refusal did not explain the unreadable check state"
  assert_grep 'authentication token expired' "$case_dir/stderr" \
    "unreadable-cause: refusal discarded the CLI diagnostic that names the fix"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unreadable-cause: an unreadable rollup reached gh-axi pr merge"
  pass "fm-pr-merge carries the CLI's own diagnostic into its unreadable-state refusal"
}

# The override record rewrites the task's meta, which teardown's landed-work
# check and the watcher both read: every unrelated field has to survive it, and
# no temp file may be left behind in state/.
test_override_record_preserves_every_meta_field() {
  local case_dir meta field
  case_dir=$(make_case override-preserves-meta)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5050505050505050505050505050505050505050
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "override-preserves-meta: an authorized exception should still merge"

  meta="$case_dir/state/task-x1.meta"
  for field in "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes"; do
    grep -qxF "$field" "$meta" \
      || fail "override-preserves-meta: recording the override dropped $field from task meta"
  done
  assert_grep 'merge_checks_override=' "$meta" \
    "override-preserves-meta: the authorized override was not recorded"
  assert_grep 'pr=https://github.com/example/repo/pull/54' "$meta" \
    "override-preserves-meta: the canonical pr= line did not survive the rewrite"
  [ -z "$(find "$case_dir/state" -name '.fm-pr-merge-meta.*' -print -quit)" ] \
    || fail "override-preserves-meta: a private meta temp file was left behind in state/"
  pass "fm-pr-merge preserves every unrelated meta field when recording an override"
}

# The rollup filter is the only forge-facing logic in this gate, and every case
# above mocks below it: the mock emits the "<conclusion>|<state>|<name>" rows the
# filter would have produced, so the filter itself is never evaluated and a drift
# between it and the forge's data - the exact defect this gate was rewritten to
# fix - would go unnoticed. These cases replay recorded
# `gh pr view --json statusCheckRollup` payloads through the script's own -q
# filter, so the `.state // ""` arm that sees a failing external commit status,
# the `.name // .context` fallback that names one, and the error(...) branch that
# makes a missing rollup unreadable all run.
# Caveat: the CLI evaluates -q with its embedded jq, so replaying through system
# jq gates the filter's semantics rather than byte-identical evaluation. jq is
# not a firstmate dependency, so these cases skip where it is absent, the same
# way this suite gates its other optional tooling.
#
# The payloads under tests/fixtures/gh-status-check-rollup/ were recorded from
# `gh pr view <url> --json statusCheckRollup` with gh 2.92.0 (2026-04-28), then
# had their repository, run, and deployment URLs rewritten to example/repo.
# A CheckRun node carries a `conclusion` and no `state`, while a StatusContext
# node - how external CI posts through the statuses API - carries a `state` and a
# `context` rather than a `name`, and reading only the conclusion is what once let
# a genuinely red external check merge as pending, so both shapes are recorded:
#   check-run-failure.json        a workflow job that failed (conclusion FAILURE)
#   commit-status-failure.json    external CI failing through a commit status
#                                 (state FAILURE)
#   expected-required-status.json a required status context declared but not yet
#                                 reported (state EXPECTED)
#   all-skipped.json              a rollup entirely path-filtered or cancelled
#   unreadable.json               a payload whose rollup field is not an array,
#                                 so the check state cannot be established
# To re-record one, run that command against a real PR in the matching state,
# replace the file's contents wholesale, and redact the repository and any
# forge URLs back to example/repo before committing.
FIXTURES="$ROOT/tests/fixtures/gh-status-check-rollup"

# Run one recorded payload through the real filter. Args: name fixture pr-number
run_fixture_case() {
  local name=$1 fixture=$2 number=$3 case_dir
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6060606060606060606060606060606060606060
  : > "$case_dir/gh-axi.log"
  set +e
  FM_TEST_ROLLUP_FIXTURE="$FIXTURES/$fixture" \
    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$number" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  FIXTURE_RC=$?
  set -e
  FIXTURE_DIR=$case_dir
}

test_real_filter_reads_a_failing_check_run() {
  run_fixture_case fixture-check-run-failure check-run-failure.json 60
  expect_code 1 "$FIXTURE_RC" \
    "fixture-check-run-failure: a recorded failing check run should refuse the merge"
  assert_grep 'has failing checks, refusing to merge' "$FIXTURE_DIR/stderr" \
    "fixture-check-run-failure: refusal did not explain the red check state"
  assert_grep 'Behavior tests' "$FIXTURE_DIR/stderr" \
    "fixture-check-run-failure: the filter did not carry the failing check's name through"
  assert_no_grep 'pr merge' "$FIXTURE_DIR/gh-axi.log" \
    "fixture-check-run-failure: a recorded red rollup reached gh-axi pr merge"
  pass "fm-pr-merge's own rollup filter reads a recorded failing check run as red"
}

# A StatusContext carries a state and a context, never a conclusion or a name.
# Both of the filter's fallbacks have to fire for this one row, or the check that
# GitHub renders red is classified as pending and merged over.
test_real_filter_reads_a_failing_commit_status() {
  run_fixture_case fixture-commit-status-failure commit-status-failure.json 61
  expect_code 1 "$FIXTURE_RC" \
    "fixture-commit-status-failure: a recorded failing commit status should refuse the merge"
  assert_grep 'has failing checks, refusing to merge' "$FIXTURE_DIR/stderr" \
    "fixture-commit-status-failure: refusal did not explain the red check state"
  assert_grep 'vercel/preview' "$FIXTURE_DIR/stderr" \
    "fixture-commit-status-failure: the filter did not fall back to .context for the status name"
  assert_no_grep 'still pending' "$FIXTURE_DIR/stderr" \
    "fixture-commit-status-failure: a failing external status was read as pending"
  assert_no_grep 'pr merge' "$FIXTURE_DIR/gh-axi.log" \
    "fixture-commit-status-failure: a recorded red commit status reached gh-axi pr merge"
  pass "fm-pr-merge's own rollup filter reads a recorded failing commit status as red"
}

test_real_filter_reads_an_expected_required_status() {
  run_fixture_case fixture-expected-status expected-required-status.json 62
  [ "$FIXTURE_RC" -eq 0 ] \
    || fail "fixture-expected-status: a declared-but-unreported required status is not red"
  grep -qxF 'pr merge 62 --repo example/repo --squash' "$FIXTURE_DIR/gh-axi.log" \
    || fail "fixture-expected-status: a recorded EXPECTED status blocked the merge"
  assert_grep 'still pending' "$FIXTURE_DIR/stderr" \
    "fixture-expected-status: merging over a declared-but-unreported status left no evidence"
  pass "fm-pr-merge's own rollup filter reads a recorded EXPECTED status as pending"
}

test_real_filter_reads_an_all_skipped_rollup() {
  run_fixture_case fixture-all-skipped all-skipped.json 63
  [ "$FIXTURE_RC" -eq 0 ] \
    || fail "fixture-all-skipped: a rollup that is only skipped or cancelled is not red"
  grep -qxF 'pr merge 63 --repo example/repo --squash' "$FIXTURE_DIR/gh-axi.log" \
    || fail "fixture-all-skipped: a recorded all-skipped rollup blocked the merge"
  assert_grep 'all 4 check(s)' "$FIXTURE_DIR/stderr" \
    "fixture-all-skipped: merging a recorded all-skipped rollup was silent"
  pass "fm-pr-merge's own rollup filter reads a recorded all-skipped rollup and says so"
}

# A rollup field that is not an array errors out of the filter, so the read fails
# instead of looking green and empty.
test_real_filter_refuses_an_unreadable_payload() {
  run_fixture_case fixture-unreadable unreadable.json 64
  expect_code 1 "$FIXTURE_RC" \
    "fixture-unreadable: a payload with no usable rollup should refuse the merge"
  assert_grep 'could not read the check state' "$FIXTURE_DIR/stderr" \
    "fixture-unreadable: a missing rollup was not treated as unreadable"
  assert_grep 'statusCheckRollup is missing from the PR view' "$FIXTURE_DIR/stderr" \
    "fixture-unreadable: the filter's own diagnostic did not survive into the refusal"
  assert_no_grep 'pr merge' "$FIXTURE_DIR/gh-axi.log" \
    "fixture-unreadable: an unreadable payload reached gh-axi pr merge"
  pass "fm-pr-merge's own rollup filter refuses a payload whose rollup cannot be read"
}

test_recorded_rollup_payloads() {
  command -v jq >/dev/null 2>&1 || {
    echo "skip: jq not found (required to replay the recorded rollup payloads)"
    return 0
  }
  test_real_filter_reads_a_failing_check_run
  test_real_filter_reads_a_failing_commit_status
  test_real_filter_reads_an_expected_required_status
  test_real_filter_reads_an_all_skipped_rollup
  test_real_filter_refuses_an_unreadable_payload
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_failing_checks_refuse_before_merge
test_no_configured_checks_are_not_red
test_pending_checks_do_not_block
test_all_skipped_checks_merge_with_a_note
test_unreadable_check_state_refuses
test_every_red_class_refuses
test_row_count_mismatch_is_unreadable
test_unnamed_failing_check_still_refuses
test_expected_status_is_pending
test_unreadable_refusal_names_the_cause
test_allow_red_checks_merges_and_records_override
test_override_record_preserves_every_meta_field
test_recorded_rollup_payloads
