#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn_argv() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_spawn() {
  local id=$1
  shift
  run_spawn_argv "$id" "$PROJECT_DIR" "$@"
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

# Publish a branch carrying content the remote default does not have, so a test
# can prove which base a spawn actually landed on rather than only that it moved.
publish_feature_branch() {  # <branch> <marker-file>
  local branch=$1 marker=$2 publisher="$CASE_DIR/publisher"
  git -C "$publisher" checkout --quiet -b "$branch"
  printf 'execution_kind lives only on this branch\n' > "$publisher/$marker"
  git -C "$publisher" add "$marker"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$branch"
  git -C "$publisher" push --quiet origin "$branch"
  git -C "$publisher" rev-parse HEAD
}

# Every brief bin/fm-brief.sh scaffolds records its base, and bin/fm-spawn.sh
# refuses an explicit --base against a brief that carries no such line, because
# such a brief predates the contract and still asserts the worktree is on a clean
# default branch. A fixture that means to reach the base machinery therefore has
# to state its base the way a real scaffolded brief does.
declare_brief_base() {  # <id> <base>
  printf 'Base contract: base=%s\n' "$2" >> "$HOME_DIR/data/$1/brief.md"
}

test_explicit_base_cuts_from_requested_branch() {
  local rec id out status feature_sha meta
  id='pool-explicit-base-r7'
  rec=$(make_case explicit-base "$id")
  read_case_record "$rec"
  feature_sha=$(publish_feature_branch feat/campaigns campaigns.txt)
  meta="$HOME_DIR/state/$id.meta"
  declare_brief_base "$id" origin/feat/campaigns

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base origin/feat/campaigns)
  status=$?
  expect_code 0 "$status" "spawn should accept an explicit base"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$feature_sha" ] \
    || fail "an explicit base did not cut the worktree from the requested branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
    || fail "fixture did not prove the requested base differs from the remote default"
  [ -f "$POOL_DIR/campaigns.txt" ] \
    || fail "the requested base is missing the feature content the task would name"
  grep -qx 'base=origin/feat/campaigns' "$meta" \
    || fail "metadata did not record the requested base"
  grep -qx "base_commit=$feature_sha" "$meta" \
    || fail "metadata did not record the resolved base commit"
  grep -qx 'base_source=requested' "$meta" \
    || fail "metadata did not record the base as requested rather than defaulted"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed explicit base: %s\n' "$(grep '^base' "$meta" | tr '\n' ' ')"
  fi
  pass "an explicit base cuts the worktree from the requested branch and records it"
}

test_defaulted_base_is_recorded_and_declared() {
  local rec id out status meta
  id='pool-default-base-r8'
  rec=$(make_case default-base "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should still launch without an explicit base"
  assert_contains "$out" 'no --base given' \
    "spawn applied the remote-default base without declaring it"
  grep -qx 'base=origin/main' "$meta" \
    || fail "metadata did not record the defaulted base"
  grep -qx 'base_source=remote-default' "$meta" \
    || fail "metadata did not distinguish a defaulted base from a requested one"
  grep -q '^base_commit=[0-9a-f]\{40\}$' "$meta" \
    || fail "metadata did not record the defaulted base commit"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed defaulted base: %s\n' "$(grep '^base' "$meta" | tr '\n' ' ')"
  fi
  pass "a defaulted base is announced and recorded as remote-default"
}

test_unknown_explicit_base_refuses() {
  local rec id out status before
  id='pool-unknown-base-r9'
  rec=$(make_case unknown-base "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  declare_brief_base "$id" origin/no-such-branch

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base origin/no-such-branch)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded on a base that does not exist"
  assert_contains "$out" 'could not fetch requested base' \
    "spawn did not clearly refuse an unresolvable requested base"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing an unresolvable requested base"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    && fail "spawn recorded metadata for a task it refused to launch"
  pass "an unresolvable requested base refuses before the worktree moves"
}

test_brief_base_contract_mismatch_refuses() {
  local rec id out status before
  id='pool-base-mismatch-r10'
  rec=$(make_case base-mismatch "$id")
  read_case_record "$rec"
  publish_feature_branch feat/campaigns campaigns.txt >/dev/null
  printf 'Delivery contract: mode=no-mistakes\nBase contract: base=origin/feat/campaigns\n' \
    > "$HOME_DIR/data/$id/brief.md"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base origin/main)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker whose brief names a different base"
  assert_contains "$out" 'base mismatch' \
    "spawn did not clearly refuse a brief/spawn base disagreement"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a base disagreement"
  pass "a brief naming a different base refuses the spawn"
}

test_unrecorded_brief_base_refuses_explicit_base() {
  local rec id out status
  id='pool-base-unrecorded-r11'
  rec=$(make_case base-unrecorded "$id")
  read_case_record "$rec"
  printf 'Delivery contract: mode=no-mistakes\nBase contract: base=unrecorded\n' \
    > "$HOME_DIR/data/$id/brief.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base origin/main)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a base its brief declares unrecorded"
  assert_contains "$out" 'declares its base unrecorded' \
    "spawn did not name the unrecorded brief base as the disagreement"
  pass "a brief declaring its base unrecorded refuses an explicit base"
}

test_base_refused_on_secondmate_spawn() {
  local rec id out status
  id='pool-base-secondmate-r12'
  rec=$(make_case base-secondmate "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --secondmate --base origin/main)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn accepted a task base"
  assert_contains "$out" '--base applies only to crewmate ship or scout spawns' \
    "a secondmate spawn did not refuse --base with its own reason"
  pass "a secondmate spawn refuses a task base"
}

test_batch_dispatch_forwards_the_requested_base() {
  local rec id out status feature_sha meta
  id='pool-batch-base-r13'
  rec=$(make_case batch-base "$id")
  read_case_record "$rec"
  feature_sha=$(publish_feature_branch feat/campaigns campaigns.txt)
  meta="$HOME_DIR/state/$id.meta"
  declare_brief_base "$id" origin/feat/campaigns

  out=$(run_spawn_argv "$id=$PROJECT_DIR" --mode no-mistakes --yolo off --base origin/feat/campaigns)
  status=$?
  expect_code 0 "$status" "batch dispatch should spawn the pair"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$feature_sha" ] \
    || fail "batch dispatch dropped the requested base and cut from somewhere else"
  [ -f "$POOL_DIR/campaigns.txt" ] \
    || fail "the batched pair is missing the feature content its requested base carries"
  grep -qx 'base=origin/feat/campaigns' "$meta" \
    || fail "batch dispatch did not record the requested base for its pair"
  grep -qx 'base_source=requested' "$meta" \
    || fail "batch dispatch recorded the base as defaulted rather than requested"
  case "$out" in
    *'no --base given'*) fail "batch dispatch announced a defaulted base despite an explicit --base" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed batched base: %s\n' "$(grep '^base' "$meta" | tr '\n' ' ')"
  fi
  pass "batch dispatch forwards the requested base to every pair it spawns"
}

# A base must be provable as current against origin, and only a branch on origin
# can be, so every other shape is refused before the worktree is touched. The
# revision expressions matter most: they resolve through whatever local ref they
# name, which `git fetch origin` never refreshes, so accepting one would land a
# task on a stale tree and record it as intended.
test_base_shape_is_restricted_to_a_branch_on_origin() {
  local rec id out status before ref stale
  id='pool-base-form-r14'
  rec=$(make_case base-form "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" fetch --quiet origin
  stale=$(git -C "$PROJECT_DIR" rev-parse main)
  [ "$stale" != "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
    || fail "fixture did not prove refs/heads/main lags origin/main"

  for ref in main 'main~1' 'main^' 'HEAD^' 'HEAD~1' 'origin/main~1' refs/heads/main \
    upstream/main v1.2.3 "$INITIAL_SHA" origin/HEAD origin/refs/heads/main origin/origin/main; do
    out=$(run_spawn "$id" --mode no-mistakes --yolo off --base "$ref")
    status=$?
    [ "$status" -ne 0 ] || fail "a ship spawn accepted the base '$ref', which cannot be proven current"
    assert_contains "$out" "$ref" "the refusal of base '$ref' did not name the value that was passed"
    assert_contains "$out" "must name a branch on origin" \
      "the refusal of base '$ref' did not say what a base must be"

    out=$(run_spawn "$id" --scout --base "$ref")
    status=$?
    [ "$status" -ne 0 ] || fail "a scout spawn accepted the base '$ref', which cannot be proven current"
    assert_contains "$out" "$ref" "the scout refusal of base '$ref' did not name the value that was passed"

    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
      || fail "spawn moved HEAD after refusing the base '$ref'"
    [ -f "$HOME_DIR/state/$id.meta" ] \
      && fail "spawn recorded metadata for the task it refused with base '$ref'"
  done
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed shape refusals with stale refs/heads/main=%s vs origin/main=%s\n' \
      "$stale" "$(git -C "$POOL_DIR" rev-parse origin/main)"
  fi
  pass "only a branch on origin is accepted as a base; every other shape is refused before the worktree moves"
}

# A base whose leading "origin/" strips to something that is not a branch name
# passes the character screen but cannot be a PR target: origin/HEAD is a
# symbolic ref that follows whichever branch the remote calls default, which is
# the unstated base this whole contract exists to eliminate. The refusal has to
# come from the shape gate and has to name the concrete remedy, rather than
# arriving later as an unrelated-sounding fetch failure.
test_a_symbolic_base_is_refused_with_the_branch_to_name_instead() {
  local rec id out status before ref
  id='pool-base-symbolic-r18'
  rec=$(make_case base-symbolic "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  for ref in origin/HEAD origin/refs/heads/main origin/origin/main; do
    out=$(run_spawn "$id" --mode no-mistakes --yolo off --base "$ref")
    status=$?
    [ "$status" -ne 0 ] || fail "a spawn accepted the base '$ref', which names no branch a PR could target"
    assert_contains "$out" "must name a branch on origin" \
      "the refusal of base '$ref' did not say what a base must be"
    assert_contains "$out" "is not a branch name" \
      "the refusal of base '$ref' did not say why the derived target is unusable"
    assert_contains "$out" "origin/feat/omp-adaptor" \
      "the refusal of base '$ref' did not point at naming the concrete branch"
    case "$out" in
      *'could not fetch requested base'*)
        fail "base '$ref' was refused by the fetch rather than by the shape gate" ;;
    esac
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
      || fail "spawn moved HEAD after refusing the base '$ref'"
    [ -f "$HOME_DIR/state/$id.meta" ] \
      && fail "spawn recorded metadata for the task it refused with base '$ref'"
  done
  pass "a base that derives no branch is refused at the shape gate, naming the branch to pass instead"
}

# A brief carrying no base contract line predates this contract, and such a brief
# does not merely omit its base: it asserts the worktree sits at a detached HEAD
# on a clean default branch. Launching it against an explicit --base would hand
# the worker exactly that false premise, so it is refused rather than warned
# about. The same brief with NO --base keeps launching as it always did.
test_legacy_brief_without_a_base_contract_refuses_an_explicit_base() {
  local rec id out status before meta
  id='pool-base-legacy-r19'
  rec=$(make_case base-legacy "$id")
  read_case_record "$rec"
  publish_feature_branch feat/campaigns campaigns.txt >/dev/null
  meta="$HOME_DIR/state/$id.meta"
  grep -q '^Base contract:' "$HOME_DIR/data/$id/brief.md" \
    && fail "fixture brief already records a base, so it cannot stand for a pre-contract brief"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base origin/feat/campaigns)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker whose brief still claims a clean default-branch base"
  assert_contains "$out" 'records no base contract line' \
    "spawn did not name the missing base contract as the reason it refused"
  assert_contains "$out" 'fm-brief.sh' \
    "spawn did not name re-scaffolding the brief as the remedy"
  # bin/fm-brief.sh refuses to overwrite an existing brief, and this arm is only
  # reached once the brief was read, so a bare "re-scaffold" would send the
  # operator into a second refusal and silently lose the filled-in task text.
  assert_contains "$out" 'aside' \
    "the remedy did not say to move the existing brief aside, so re-scaffolding would refuse"
  assert_contains "$out" '# Task' \
    "the remedy did not say to restore the task text a fresh scaffold replaces"
  assert_contains "$out" 'origin/feat/campaigns' \
    "spawn did not name the base to re-scaffold the brief with"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a brief that records no base"
  [ -f "$meta" ] && fail "spawn recorded metadata for the task it refused to launch"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the same pre-contract brief with no --base should launch exactly as before"
  grep -qx 'base_source=remote-default' "$meta" \
    || fail "a pre-contract brief without --base stopped taking the remote-default base"
  pass "a brief recording no base refuses an explicit base and still launches without one"
}

test_local_only_base_must_be_the_branch_the_merge_fast_forwards() {
  local rec id out status before meta
  id='pool-local-only-base-r17'
  rec=$(make_case local-only-base "$id")
  read_case_record "$rec"
  publish_feature_branch feat/campaigns campaigns.txt >/dev/null
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  declare_brief_base "$id" origin/feat/campaigns

  out=$(run_spawn "$id" --mode local-only --yolo off --base origin/feat/campaigns)
  status=$?
  [ "$status" -ne 0 ] || fail "a local-only task was cut from a base its guarded merge can never fast-forward"
  assert_contains "$out" "cannot be combined with --mode local-only" \
    "spawn did not explain why a local-only task cannot use a non-default base"
  assert_contains "$out" "fm-merge-local.sh" \
    "spawn did not name the landing path that makes the default branch authoritative"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a local-only base"

  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  declare_brief_base "$id" "origin/$DEFAULT_BRANCH"
  out=$(run_spawn "$id" --mode local-only --yolo off --base "origin/$DEFAULT_BRANCH")
  status=$?
  expect_code 0 "$status" "a local-only task based on the default branch should still launch"
  meta="$HOME_DIR/state/$id.meta"
  grep -qx "base=origin/$DEFAULT_BRANCH" "$meta" \
    || fail "a local-only task did not record the default branch it was based on"
  pass "a local-only base is constrained to the branch its guarded merge fast-forwards"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_explicit_base_cuts_from_requested_branch
test_defaulted_base_is_recorded_and_declared
test_unknown_explicit_base_refuses
test_brief_base_contract_mismatch_refuses
test_unrecorded_brief_base_refuses_explicit_base
test_base_refused_on_secondmate_spawn
test_batch_dispatch_forwards_the_requested_base
test_base_shape_is_restricted_to_a_branch_on_origin
test_a_symbolic_base_is_refused_with_the_branch_to_name_instead
test_legacy_brief_without_a_base_contract_refuses_an_explicit_base
test_local_only_base_must_be_the_branch_the_merge_fast_forwards

echo "# all fm-spawn-pool-base-freshen tests passed"
