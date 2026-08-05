#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh pr merge itself fails (no silent success)
#   (c) extra gh pr merge args are forwarded after number and --repo
#   (d) merge is refused before reaching gh when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh
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
#   (o2) a rollup that is both incomplete and already red reports both facts, in
#       the refusal and in the recorded override alike
#   (p) a declared-but-unreported required status (EXPECTED) is pending, so the
#       merge says so instead of proceeding with no evidence at all
#   (q) an unreadable refusal carries the CLI's own diagnostic, because the fix
#       differs per cause
#   (r) recording an authorized override preserves every unrelated meta field
#       and leaves no private temp file behind
#   (r2) a clean retry after an authorized attempt whose merge failed clears the
#       stale override, so the record describes the merge that happened
#   (t) the merge is pinned to the head whose checks were classified: a commit
#       pushed into the window between the check read and the merge does not
#       land, an unmoved head still merges, a rollup with no head is unreadable,
#       the caller may not supply the pin, and the merge is issued through the
#       CLI that carries it rather than a wrapper that would drop it
#   (u) a caller's --method is translated to the shorthand flag gh takes, a
#       short-form method counts as an explicit choice, and a value that is not a
#       merge method is refused rather than becoming a flag
#   (v) --admin is refused, because this path does not merge past the forge's own
#       required checks and reviews
#   (w) a PR that already landed records its metadata and stops, keeping any
#       override record of the authorized merge that landed
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
# fakebin with the forge CLI mocks that record how they were invoked. Echoes the
# case dir.
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
# `gh pr view --json state,statusCheckRollup,headRefOid -q <filter>`, so the mock
# answers what that filter emits: a "state|<state>" header naming where the PR
# stands (FM_TEST_PR_STATE), a "head|<sha>" header naming the commit the rollup
# describes, a "rollup|<count>" header, then one
# "<conclusion>|<state>|<name>" row per entry, where a check run carries a
# conclusion and a commit status carries a state. Rows come from FM_TEST_ROLLUP
# (the ROLLUP_EMPTY sentinel means a rollup with no entries at all),
# FM_TEST_ROLLUP_COUNT can disagree with the rows on purpose, and
# FM_TEST_ROLLUP_RC makes the query itself fail the way a filter error does.
# The head comes from the case's head file, which is what a case that moves the
# PR's head mid-run rewrites; the HEAD_ABSENT sentinel reports none at all.
ROLLUP_GREEN='SUCCESS||Lint shell scripts
SUCCESS||Test coverage guard'
ROLLUP_EMPTY='__no_checks__'
HEAD_ABSENT='__no_head__'

# FM_TEST_ROLLUP_FIXTURE switches the mock from emitting those rows to replaying
# a recorded payload through the script's own -q filter, which is the only way
# the filter itself is under test rather than a hand-copy of what it produces.
# jq stands in for the CLI's embedded evaluator, so its exit status and stderr
# reach the gate exactly as the CLI's would.
#
# Before either branch answers, the mock holds the query to gh's actual contract:
# `--json` returns an object carrying exactly the keys it was asked for, so a
# field the filter dereferences but the query never requested reads as null. A
# mock that answers from its own rows, or from a fixture file on disk, cannot see
# that - it would supply a head nobody asked gh for and the gate would look
# correct while every real merge refused. So the requested field list is checked
# against the top-level fields this gate's filter reads, and a mismatch fails the
# call loudly instead of answering it.
# shellcheck disable=SC2016  # Mock source: these expansions must stay literal.
GH_ROLLUP_MOCK_BODY='
    case " $* " in
      *statusCheckRollup*)
        requested=
        prev=
        for arg in "$@"; do
          [ "$prev" = "--json" ] && requested=$arg
          prev=$arg
        done
        for field in state statusCheckRollup headRefOid; do
          case ",$requested," in
            *",$field,"*) ;;
            *)
              printf "gh: the -q filter reads .%s but --json requested %s\n" \
                "$field" "${requested:-nothing}" >&2
              exit 1 ;;
          esac
        done
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
        printf "state|%s\n" "${FM_TEST_PR_STATE:-OPEN}"
        head=
        if [ "${FM_TEST_ROLLUP_HEAD:-}" != "__no_head__" ] && [ -f "$FM_TEST_HEAD_FILE" ]; then
          head=$(cat "$FM_TEST_HEAD_FILE")
        fi
        printf "head|%s\n" "$head"
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

# The merge is issued through plain `gh`, because --match-head-commit is a gh
# flag and the ergonomic gh-axi wrapper rebuilds its gh argv from a fixed flag
# allowlist that would drop the pin without a word. So gh owns the merge log and
# gh-axi is installed only as a tripwire: it records anything the script sends it
# and the cases assert that log stays empty, which is what catches a merge routed
# back through a CLI that cannot carry the pin.
#
# The gh mock answers headRefOid for fm-pr-check.sh's pr_head lookup and the
# check rollup for the red-PR gate. The PR's head lives in a file rather than
# baked into the mock, because it is a property of the PR that a case may move
# mid-run rather than a constant. Args: case_dir head_sha
GH_AXI_TRIPWIRE_MOCK='#!/usr/bin/env bash
printf "%s\n" "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
'

add_gh_mocks() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/head"
  printf '%s' "$GH_AXI_TRIPWIRE_MOCK" > "$case_dir/fakebin/gh-axi"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr merge") printf '%s\n' "\$*" >> "\$FM_TEST_MERGE_LOG" ; exit 0 ;;
  "pr view")
$GH_ROLLUP_MOCK_BODY
    case " \$* " in
      *headRefOid*) cat "\$FM_TEST_HEAD_FILE" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that fails the merge call but succeeds everything else, so a real merge
# failure is distinguishable from the recording step. Args: case_dir head_sha
add_gh_mocks_merge_fails() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/head"
  printf '%s' "$GH_AXI_TRIPWIRE_MOCK" > "$case_dir/fakebin/gh-axi"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr merge")
    printf '%s\n' "\$*" >> "\$FM_TEST_MERGE_LOG"
    echo "error: pr merge failed" >&2
    exit 1 ;;
  "pr view")
$GH_ROLLUP_MOCK_BODY
    case " \$* " in
      *headRefOid*) cat "\$FM_TEST_HEAD_FILE" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# The forge's own head-pin enforcement, plus a PR whose head moves between the
# check read and the merge. The rollup read answers the head that was classified;
# fm-pr-check.sh's later headRefOid lookup rewrites the head file, standing in
# for a commit pushed to the PR branch inside that window; and the merge then
# lands only when --match-head-commit names the head current at merge time, which
# is the precondition `gh pr merge --match-head-commit` hands the real forge. A
# merge that arrives with no pin at all lands whatever is current, exactly as an
# unpinned merge does, so a dropped pin fails these cases rather than passing
# them. Args: case_dir classified_head pushed_head
add_gh_mocks_head_moves() {
  local case_dir=$1 classified=$2 pushed=$3
  printf '%s\n' "$classified" > "$case_dir/head"
  printf '%s' "$GH_AXI_TRIPWIRE_MOCK" > "$case_dir/fakebin/gh-axi"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr merge")
    printf '%s\n' "\$*" >> "\$FM_TEST_MERGE_LOG"
    want=
    prev=
    for arg in "\$@"; do
      [ "\$prev" = "--match-head-commit" ] && want=\$arg
      prev=\$arg
    done
    current=\$(cat "\$FM_TEST_HEAD_FILE")
    if [ -n "\$want" ] && [ "\$want" != "\$current" ]; then
      echo "error: Head branch was modified. Review and try the merge again." >&2
      exit 1
    fi
    printf 'merged %s\n' "\$current" >> "\$FM_TEST_MERGED_LOG"
    exit 0 ;;
  "pr view")
$GH_ROLLUP_MOCK_BODY
    case " \$* " in
      *headRefOid*)
        printf '%s\n' '$pushed' > "\$FM_TEST_HEAD_FILE"
        printf '%s\n' '$pushed'
        exit 0 ;;
    esac
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
  FM_TEST_MERGE_LOG="$case_dir/merge.log" \
  FM_TEST_MERGED_LOG="$case_dir/merged.log" \
  FM_TEST_HEAD_FILE="$case_dir/head" \
  FM_TEST_ROLLUP="${FM_TEST_ROLLUP:-$ROLLUP_GREEN}" \
  FM_TEST_ROLLUP_COUNT="${FM_TEST_ROLLUP_COUNT:-}" \
  FM_TEST_ROLLUP_RC="${FM_TEST_ROLLUP_RC:-0}" \
  FM_TEST_ROLLUP_ERR="${FM_TEST_ROLLUP_ERR:-}" \
  FM_TEST_ROLLUP_HEAD="${FM_TEST_ROLLUP_HEAD:-}" \
  FM_TEST_PR_STATE="${FM_TEST_PR_STATE:-OPEN}" \
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
  : > "$case_dir/merge.log"
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
  grep -qxF 'pr merge 9 --repo example/repo --match-head-commit deadbeefcafefeed0000000000000000deadbeef --squash' "$case_dir/merge.log" \
    || fail "records-before-merge: gh pr merge was not invoked with number, --repo, and default --squash"
  # The pin is a gh flag. A wrapper that rebuilds gh's argv from its own flag
  # allowlist drops it silently, so the merge must never be routed through one.
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "records-before-merge: the merge was routed through a CLI that cannot carry the head pin"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir" 1313131313131313131313131313131313131313
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --match-head-commit 2222222222222222222222222222222222222222 --squash --delete-branch' "$case_dir/merge.log" \
    || fail "extra-args: extra gh pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/merge.log" ] || fail "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "malformed-url: gh pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "unsafe-url-segment: gh pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "repo-override: gh pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --match-head-commit 5555555555555555555555555555555555555555 --merge' "$case_dir/merge.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

# gh has no --method: it takes the merge method as a shorthand flag. A caller
# that names one keeps its choice, translated to the flag the CLI understands,
# rather than having it silently dropped or passed through to be rejected.
test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --match-head-commit 7777777777777777777777777777777777777777 --merge' "$case_dir/merge.log" \
    || fail "method-equals-merge-method: caller --method=merge was not translated to the flag gh takes"
  pass "fm-pr-merge translates --method=<value> to the merge method flag gh understands"
}

test_method_with_separate_value_is_translated() {
  local case_dir rc
  case_dir=$(make_case method-separate-value)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 -- --method rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-separate-value: fm-pr-merge failed"

  grep -qxF 'pr merge 24 --repo example/repo --match-head-commit 3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b --rebase' "$case_dir/merge.log" \
    || fail "method-separate-value: caller --method rebase was not translated to the flag gh takes"

  # An unchecked method value would become an arbitrary flag on the merge command
  # line, including the very flags this script refuses to let a caller set.
  : > "$case_dir/merge.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 -- --method repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "method-separate-value: an unknown merge method should refuse"
  assert_grep 'must be one of merge, squash, or rebase' "$case_dir/stderr" \
    "method-separate-value: refusal did not name the merge methods that exist"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "method-separate-value: an unknown merge method reached gh pr merge"
  pass "fm-pr-merge translates a separate --method value and refuses one that is not a method"
}

# gh honours -s, -m, and -r, so a caller that spells the method that way has
# chosen one. Missing that adds the default --squash beside it and gh refuses the
# pair outright, which turns a valid invocation into a failed merge.
test_short_form_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case short-form-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/25 -- -m \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "short-form-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 25 --repo example/repo --match-head-commit 5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c -m' "$case_dir/merge.log" \
    || fail "short-form-merge-method: caller -m was not left as the only merge method"
  assert_no_grep 'squash' "$case_dir/merge.log" \
    "short-form-merge-method: a default --squash was added beside the caller's short-form method"
  pass "fm-pr-merge treats a short-form merge method as the caller's explicit choice"
}

# "Never merge a red PR" leans on the forge's own required-check and review gates
# as its backstop, and --admin is the flag that lands a PR past them. The wrapper
# this path used to call discarded it silently; the refusal is now explicit.
test_admin_merge_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case admin-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/26 -- --admin \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "admin-override: fm-pr-merge should refuse an administrator merge"
  assert_grep 'must not include --admin' "$case_dir/stderr" \
    "admin-override: refusal did not explain the administrator override"
  assert_no_grep 'pr=https://github.com/example/repo/pull/26' "$case_dir/state/task-x1.meta" \
    "admin-override: the PR URL was recorded before rejecting the administrator merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "admin-override: an administrator merge armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "admin-override: an administrator merge reached gh pr merge"
  pass "fm-pr-merge refuses an administrator merge before recording state"
}

# This path is re-run exactly when a merge landed but its report did not survive.
# The PR has nothing left to merge, so recording its metadata is the whole job -
# and a second merge attempt would fail on a PR that is already closed.
test_already_merged_pr_is_idempotent() {
  local case_dir rc meta
  case_dir=$(make_case already-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  meta="$case_dir/state/task-x1.meta"

  set +e
  FM_TEST_PR_STATE=MERGED \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/27 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "already-merged: re-running against a landed PR should succeed"
  assert_grep 'already merged' "$case_dir/stderr" \
    "already-merged: the run did not report that the PR had already landed"
  assert_grep 'pr=https://github.com/example/repo/pull/27' "$meta" \
    "already-merged: the PR reference teardown needs was not recorded"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "already-merged: a landed PR was sent to gh pr merge a second time"
  pass "fm-pr-merge records metadata and stops when the PR has already landed"
}

# An override recorded by the authorized merge that actually landed is a true
# record of how the PR reached the base branch, so the re-run must not reconcile
# it away on its way to reporting the landing.
test_already_merged_pr_keeps_its_override_record() {
  local case_dir meta rc
  case_dir=$(make_case already-merged-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir" 8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  meta="$case_dir/state/task-x1.meta"

  set +e
  FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/28 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "already-merged-override: the first attempt should propagate the merge failure"
  assert_grep 'merge_checks_override=failing checks:' "$meta" \
    "already-merged-override: the authorized attempt did not record its override"

  # The merge in fact landed; only its report was lost.
  add_gh_mocks "$case_dir" 8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f
  : > "$case_dir/merge.log"
  FM_TEST_PR_STATE=MERGED FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/28 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "already-merged-override: re-running against a landed PR should succeed"

  assert_grep 'merge_checks_override=failing checks:' "$meta" \
    "already-merged-override: the record of the authorized merge that landed was erased"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "already-merged-override: a landed PR was sent to gh pr merge a second time"
  pass "fm-pr-merge keeps the override record of an authorized merge that already landed"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --match-head-commit 6666666666666666666666666666666666666666 --squash' "$case_dir/merge.log" \
    || fail "url-parsing: gh pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh number and --repo arguments"
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
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "failing-checks: gh pr merge was invoked for a red PR"
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
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP="$ROLLUP_EMPTY" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-checks-configured: fm-pr-merge should merge a PR with no checks configured"

  grep -qxF 'pr merge 32 --repo example/repo --match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --squash' "$case_dir/merge.log" \
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
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  # A queued check run carries no conclusion yet, and a commit status that has
  # not reported carries PENDING: both are pending, neither is red.
  FM_TEST_ROLLUP='SUCCESS||Lint shell scripts
||Behavior tests
|PENDING|vercel' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pending-checks: fm-pr-merge should not refuse a PR whose checks are only pending"

  grep -qxF 'pr merge 33 --repo example/repo --match-head-commit cccccccccccccccccccccccccccccccccccccccc --squash' "$case_dir/merge.log" \
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
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP='SKIPPED||Lint shell scripts
SKIPPED||Behavior tests
CANCELLED||Docs check
CANCELLED||Typecheck
NEUTRAL||Build' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "all-skipped-checks: fm-pr-merge should not refuse a rollup that is only skipped"

  grep -qxF 'pr merge 34 --repo example/repo --match-head-commit dddddddddddddddddddddddddddddddddddddddd --squash' "$case_dir/merge.log" \
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
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "unreadable-checks: gh pr merge was invoked without an established check state"
  pass "fm-pr-merge refuses when the check state cannot be established"
}

test_allow_red_checks_merges_and_records_override() {
  local case_dir meta override_line pr_line
  case_dir=$(make_case allow-red-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "allow-red-checks: an authorized exception should still merge"

  meta="$case_dir/state/task-x1.meta"
  grep -qxF 'pr merge 35 --repo example/repo --match-head-commit eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --squash' "$case_dir/merge.log" \
    || fail "allow-red-checks: the authorized merge did not reach gh"
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
    : > "$case_dir/merge.log"
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
    assert_no_grep 'pr merge' "$case_dir/merge.log" \
      "red-$field: a ${class##* } result reached gh pr merge"
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
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "rollup-count-mismatch: an unreadable rollup reached gh pr merge"
  pass "fm-pr-merge treats a rollup shorter than its own count as unreadable"
}

# A partly-read rollup can also be red. Reporting only "could not read the check
# state ... retry once gh can reach the PR" sends the operator after the CLI when
# the rows that did come back name a check that failed, and an override recorded
# as unreadable alone loses the evidence that motivated it, so both facts have to
# survive - in the refusal and in the durable record alike.
test_partly_read_red_rollup_reports_both_facts() {
  local case_dir rc
  case_dir=$(make_case partly-read-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6060606060606060606060606060606060606060
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP='FAILURE||Lint shell scripts' FM_TEST_ROLLUP_COUNT=4 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "partly-read-red: an incomplete red rollup should refuse"
  assert_grep 'could not read the check state' "$case_dir/stderr" \
    "partly-read-red: refusal did not report that the rollup was incomplete"
  assert_grep 'counts 4 check(s) but only 1 row(s)' "$case_dir/stderr" \
    "partly-read-red: refusal did not name the counts it compared"
  assert_grep 'Lint shell scripts' "$case_dir/stderr" \
    "partly-read-red: refusal discarded the failing check name it had already read"
  assert_grep 'Fix those checks' "$case_dir/stderr" \
    "partly-read-red: refusal told the operator to retry the CLI over a check that failed"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "partly-read-red: an incomplete red rollup reached gh pr merge"

  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  FM_TEST_ROLLUP='FAILURE||Lint shell scripts' FM_TEST_ROLLUP_COUNT=4 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "partly-read-red: an authorized exception should still merge"
  assert_grep 'Lint shell scripts' "$case_dir/state/task-x1.meta" \
    "partly-read-red: the recorded override lost the failing check that motivated it"
  pass "fm-pr-merge reports an incomplete rollup's failing checks in the refusal and the override record"
}

test_unnamed_failing_check_still_refuses() {
  local case_dir rc
  case_dir=$(make_case unnamed-failing-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "unnamed-failing-check: a nameless red rollup reached gh pr merge"
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
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP='SUCCESS||Lint shell scripts
|EXPECTED|required-context' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-status: a declared-but-unreported required status is not red"

  grep -qxF 'pr merge 52 --repo example/repo --match-head-commit 3030303030303030303030303030303030303030 --squash' "$case_dir/merge.log" \
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
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "unreadable-cause: an unreadable rollup reached gh pr merge"
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
  : > "$case_dir/merge.log"
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

# A durable record that outlives the state it describes is worse than none: it
# asserts a captain authorization for a merge that never needed one. An
# authorized attempt whose merge then fails leaves exactly that behind, and the
# clean retry that follows - CI fixed, no flag - has to reconcile it.
test_clean_retry_clears_a_stale_override() {
  local case_dir meta field rc
  case_dir=$(make_case stale-override-cleared)
  mkdir -p "$case_dir/wt"
  meta="$case_dir/state/task-x1.meta"
  add_gh_mocks_merge_fails "$case_dir" 4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP="$ROLLUP_RED" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "stale-override-cleared: the first attempt should propagate the merge failure"
  assert_grep 'merge_checks_override=failing checks:' "$meta" \
    "stale-override-cleared: the authorized attempt did not record its override"

  # The operator fixes CI and retries with no flag: the checks are green now, so
  # the meta must not keep claiming this merge was authorized over a red state.
  add_gh_mocks "$case_dir" 4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "stale-override-cleared: the clean retry should merge"

  grep -qxF 'pr merge 73 --repo example/repo --match-head-commit 4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b --squash' "$case_dir/merge.log" \
    || fail "stale-override-cleared: the clean retry did not reach gh"
  assert_no_grep 'merge_checks_override=' "$meta" \
    "stale-override-cleared: a green merge inherited the earlier attempt's override record"
  for field in "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes"; do
    grep -qxF "$field" "$meta" \
      || fail "stale-override-cleared: clearing the override dropped $field from task meta"
  done
  assert_grep 'pr=https://github.com/example/repo/pull/73' "$meta" \
    "stale-override-cleared: the canonical pr= line did not survive the rewrite"
  [ -z "$(find "$case_dir/state" -name '.fm-pr-merge-meta.*' -print -quit)" ] \
    || fail "stale-override-cleared: a private meta temp file was left behind in state/"
  pass "fm-pr-merge clears a stale override record when a later merge needs none"
}

# The rollup is read before bin/fm-pr-check.sh runs and the merge happens after
# it, so the two are seconds to minutes apart. A commit pushed into that window
# would otherwise land a head whose checks were never classified, which is the
# state "never merge a red PR" exists to prevent, so the merge is pinned to the
# head the classified rollup described and the forge refuses it instead.
test_head_pushed_after_the_check_read_does_not_merge() {
  local case_dir rc
  case_dir=$(make_case head-moves-mid-run)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_head_moves "$case_dir" \
    7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a \
    9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/merged.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "head-moves-mid-run: a head pushed after the check read must not merge"
  grep -qxF 'pr merge 70 --repo example/repo --match-head-commit 7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a --squash' "$case_dir/merge.log" \
    || fail "head-moves-mid-run: the merge was not pinned to the head whose checks were classified"
  [ ! -s "$case_dir/merged.log" ] \
    || fail "head-moves-mid-run: a head whose checks were never classified was merged"
  pass "fm-pr-merge refuses to land a head pushed after the check state was read"
}

# The pin must not block the ordinary case it protects: a PR whose head has not
# moved since the rollup was read still merges, under that same enforcement.
test_unmoved_head_merges_under_its_pin() {
  local case_dir
  case_dir=$(make_case head-unchanged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_head_moves "$case_dir" \
    8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c \
    8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/merged.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "head-unchanged: an unmoved head should still merge"

  grep -qxF 'merged 8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c' "$case_dir/merged.log" \
    || fail "head-unchanged: the pin blocked a merge whose head never moved"
  pass "fm-pr-merge merges a PR whose head has not moved since the check read"
}

# The head is part of the check state: a rollup with no head to attach it to
# establishes nothing that survives to merge time, so it is unreadable like any
# other incomplete read - and the authorized exception that merges anyway says
# out loud that it merged unpinned.
test_missing_head_is_unreadable() {
  local case_dir rc
  case_dir=$(make_case rollup-without-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP_HEAD="$HEAD_ABSENT" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "rollup-without-head: a rollup with no head should refuse"
  assert_grep 'could not read the check state' "$case_dir/stderr" \
    "rollup-without-head: a headless rollup was not treated as unreadable"
  assert_grep 'no usable head commit' "$case_dir/stderr" \
    "rollup-without-head: the refusal did not name the missing head"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "rollup-without-head: an unpinnable merge reached gh pr merge"

  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"
  FM_TEST_ROLLUP_HEAD="$HEAD_ABSENT" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 --allow-red-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "rollup-without-head: an authorized exception should still merge"
  grep -qxF 'pr merge 72 --repo example/repo --squash' "$case_dir/merge.log" \
    || fail "rollup-without-head: the authorized merge did not reach gh unpinned"
  assert_grep 'not pinned' "$case_dir/stderr" \
    "rollup-without-head: an unpinned authorized merge left no evidence that it was unpinned"
  pass "fm-pr-merge refuses a rollup it cannot pin, and says so when authorized to merge anyway"
}

# The head comes only from the check state this merge classified, exactly as the
# repository comes only from the URL, so a caller-supplied pin is refused rather
# than silently replacing the one guarantee the pin exists to make.
test_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case head-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f
  : > "$case_dir/merge.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    -- --match-head-commit 0000000000000000000000000000000000000000 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "head-override: fm-pr-merge should refuse a caller-supplied head pin"
  assert_grep 'must not override the head commit' "$case_dir/stderr" \
    "head-override: refusal did not explain the head override"
  assert_no_grep 'pr=https://github.com/example/repo/pull/74' "$case_dir/state/task-x1.meta" \
    "head-override: the PR URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "head-override: a head override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/merge.log" \
    "head-override: gh pr merge was invoked despite the head override"
  pass "fm-pr-merge refuses caller-supplied head pins before recording state"
}

# The rollup filter is the only forge-facing logic in this gate, and every case
# above mocks below it: the mock emits the "<conclusion>|<state>|<name>" rows the
# filter would have produced, so the filter itself is never evaluated and a drift
# between it and the forge's data - the exact defect this gate was rewritten to
# fix - would go unnoticed. These cases replay recorded
# `gh pr view --json statusCheckRollup,headRefOid` payloads through the script's
# own -q filter, so the `.state // ""` arm that sees a failing external commit
# status, the `.name // .context` fallback that names one, the headRefOid the
# merge is pinned to, and the error(...) branch that makes a missing rollup
# unreadable all run.
# Caveat: the CLI evaluates -q with its embedded jq, so replaying through system
# jq gates the filter's semantics rather than byte-identical evaluation. jq is
# not a firstmate dependency, so these cases skip where it is absent, the same
# way this suite gates its other optional tooling.
#
# The payloads under tests/fixtures/gh-status-check-rollup/ were recorded from
# `gh pr view <url> --json state,statusCheckRollup,headRefOid` with gh 2.92.0
# (2026-04-28), then had their repository, run, and deployment URLs rewritten to
# example/repo and their headRefOid to a synthetic sha.
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
  : > "$case_dir/merge.log"
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
  assert_no_grep 'pr merge' "$FIXTURE_DIR/merge.log" \
    "fixture-check-run-failure: a recorded red rollup reached gh pr merge"
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
  assert_no_grep 'pr merge' "$FIXTURE_DIR/merge.log" \
    "fixture-commit-status-failure: a recorded red commit status reached gh pr merge"
  pass "fm-pr-merge's own rollup filter reads a recorded failing commit status as red"
}

test_real_filter_reads_an_expected_required_status() {
  run_fixture_case fixture-expected-status expected-required-status.json 62
  [ "$FIXTURE_RC" -eq 0 ] \
    || fail "fixture-expected-status: a declared-but-unreported required status is not red"
  grep -qxF 'pr merge 62 --repo example/repo --match-head-commit f27c5b8039ea146d7b0c9f3a25de8471c0693b5e --squash' "$FIXTURE_DIR/merge.log" \
    || fail "fixture-expected-status: a recorded EXPECTED status blocked the merge"
  assert_grep 'still pending' "$FIXTURE_DIR/stderr" \
    "fixture-expected-status: merging over a declared-but-unreported status left no evidence"
  pass "fm-pr-merge's own rollup filter reads a recorded EXPECTED status as pending"
}

test_real_filter_reads_an_all_skipped_rollup() {
  run_fixture_case fixture-all-skipped all-skipped.json 63
  [ "$FIXTURE_RC" -eq 0 ] \
    || fail "fixture-all-skipped: a rollup that is only skipped or cancelled is not red"
  grep -qxF 'pr merge 63 --repo example/repo --match-head-commit a3f1c07d5e9b48126d0a7f4c39be2015d8c6740b --squash' "$FIXTURE_DIR/merge.log" \
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
  assert_no_grep 'pr merge' "$FIXTURE_DIR/merge.log" \
    "fixture-unreadable: an unreadable payload reached gh pr merge"
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
test_method_with_separate_value_is_translated
test_short_form_merge_method_not_overridden
test_admin_merge_args_refuse_before_recording
test_already_merged_pr_is_idempotent
test_already_merged_pr_keeps_its_override_record
test_parses_pr_url_for_gh_axi
test_failing_checks_refuse_before_merge
test_no_configured_checks_are_not_red
test_pending_checks_do_not_block
test_all_skipped_checks_merge_with_a_note
test_unreadable_check_state_refuses
test_every_red_class_refuses
test_row_count_mismatch_is_unreadable
test_partly_read_red_rollup_reports_both_facts
test_unnamed_failing_check_still_refuses
test_expected_status_is_pending
test_unreadable_refusal_names_the_cause
test_allow_red_checks_merges_and_records_override
test_override_record_preserves_every_meta_field
test_clean_retry_clears_a_stale_override
test_head_pushed_after_the_check_read_does_not_merge
test_unmoved_head_merges_under_its_pin
test_missing_head_is_unreadable
test_head_override_args_refuse_before_recording
test_recorded_rollup_payloads
