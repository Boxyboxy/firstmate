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

# Tag origin at the publisher's current tip, so a test can request a base that is
# a tag rather than a branch. An annotated tag resolves to a TAG OBJECT rather
# than a commit, which is the case that separates a peeled comparison from a raw
# one, so it is published on request.
publish_tag() {  # <tag> [annotated]
  local tag=$1 annotated=${2:-} publisher="$CASE_DIR/publisher"
  if [ -n "$annotated" ]; then
    git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      tag -a "$tag" -m "$tag"
  else
    git -C "$publisher" tag "$tag"
  fi
  git -C "$publisher" push --quiet origin "$tag"
  git -C "$publisher" rev-parse "$tag^{commit}"
}

# Publish a tag on origin whose commit is on no branch at all, so the pool's
# plain `git fetch origin` cannot pick it up by following the branch refspec.
# This is the shape a clone that does not already carry the tag presents.
publish_unreachable_tag() {  # <tag> <marker-file>
  local tag=$1 marker=$2 publisher="$CASE_DIR/publisher" sha
  git -C "$publisher" checkout --quiet --detach
  printf 'reachable only through the tag\n' > "$publisher/$marker"
  git -C "$publisher" add "$marker"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$tag"
  git -C "$publisher" tag "$tag"
  sha=$(git -C "$publisher" rev-parse HEAD)
  git -C "$publisher" push --quiet origin "refs/tags/$tag"
  git -C "$publisher" checkout --quiet -
  printf '%s\n' "$sha"
}

test_explicit_base_cuts_from_requested_branch() {
  local rec id out status feature_sha meta
  id='pool-explicit-base-r7'
  rec=$(make_case explicit-base "$id")
  read_case_record "$rec"
  feature_sha=$(publish_feature_branch feat/campaigns campaigns.txt)
  meta="$HOME_DIR/state/$id.meta"

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

test_ship_base_must_name_a_branch_on_origin() {
  local rec id out status before ref
  id='pool-base-form-r14'
  rec=$(make_case base-form "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  for ref in main upstream/main v1.2.3 "$INITIAL_SHA"; do
    out=$(run_spawn "$id" --mode no-mistakes --yolo off --base "$ref")
    status=$?
    [ "$status" -ne 0 ] || fail "a ship spawn accepted the base '$ref', which names no branch on origin"
    assert_contains "$out" "must name a branch on origin" \
      "a ship spawn did not say why the base '$ref' cannot be a ship base"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
      || fail "spawn moved HEAD after refusing the base '$ref'"
  done
  [ -f "$HOME_DIR/state/$id.meta" ] \
    && fail "spawn recorded metadata for a task it refused to launch"
  pass "a ship base that names no branch on origin is refused before the worktree moves"
}

test_stale_local_branch_base_is_refused() {
  local rec id out status before stale current
  id='pool-stale-local-base-r15'
  rec=$(make_case stale-local-base "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  stale=$(git -C "$PROJECT_DIR" rev-parse main)

  # A scout may name a ref that is not origin/<branch>, so this is the path where
  # a bare branch name could still reach the worktree. refs/heads/main is exactly
  # what `git fetch origin` never updates.
  out=$(run_spawn "$id" --scout --base main)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a local branch that git fetch origin never refreshes"
  assert_contains "$out" "refs/heads/main" \
    "spawn did not name the stale local ref it refused to resolve through"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a stale local base"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    && fail "spawn recorded metadata for a task it refused to launch"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$stale" != "$current" ] \
    || fail "fixture did not prove refs/heads/main lags origin/main"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-local refusal: %s (refs/heads/main=%s origin/main=%s)\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$stale" "$current"
  fi
  pass "a base resolving through a local branch is refused instead of silently launched stale"
}

test_scout_base_may_be_a_tag_or_a_commit() {
  local rec id out status tag_sha meta
  id='pool-scout-tag-base-r16'
  rec=$(make_case scout-tag-base "$id")
  read_case_record "$rec"
  tag_sha=$(publish_tag release-candidate)
  meta="$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id" --scout --base release-candidate)
  status=$?
  expect_code 0 "$status" "a scout spawn should accept a tag published on origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tag_sha" ] \
    || fail "a scout spawn did not cut its worktree from the requested tag"
  grep -qx 'base=release-candidate' "$meta" || fail "metadata did not record the requested tag base"
  grep -qx 'base_source=requested' "$meta" || fail "a tag base was not recorded as requested"

  id='pool-scout-commit-base-r16'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --scout --base "$tag_sha")
  status=$?
  expect_code 0 "$status" "a scout spawn should accept an immutable commit as a base"
  grep -qx "base_commit=$tag_sha" "$HOME_DIR/state/$id.meta" \
    || fail "a commit base was not recorded as the resolved base commit"
  pass "a scout base may be a tag or a commit the spawn can still prove current"
}

test_local_only_base_must_be_the_branch_the_merge_fast_forwards() {
  local rec id out status before meta
  id='pool-local-only-base-r17'
  rec=$(make_case local-only-base "$id")
  read_case_record "$rec"
  publish_feature_branch feat/campaigns campaigns.txt >/dev/null
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off --base origin/feat/campaigns)
  status=$?
  [ "$status" -ne 0 ] || fail "a local-only task was cut from a base its guarded merge can never fast-forward"
  assert_contains "$out" "cannot be combined with --mode local-only" \
    "spawn did not explain why a local-only task cannot use a non-default base"
  assert_contains "$out" "fm-merge-local.sh" \
    "spawn did not name the landing path that makes the default branch authoritative"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a local-only base"

  out=$(run_spawn "$id" --mode local-only --yolo off --base "origin/$DEFAULT_BRANCH")
  status=$?
  expect_code 0 "$status" "a local-only task based on the default branch should still launch"
  meta="$HOME_DIR/state/$id.meta"
  grep -qx "base=origin/$DEFAULT_BRANCH" "$meta" \
    || fail "a local-only task did not record the default branch it was based on"
  pass "a local-only base is constrained to the branch its guarded merge fast-forwards"
}

test_annotated_tag_base_records_the_commit_it_cut() {
  local rec id out status tag_commit meta
  id='pool-annotated-tag-r18'
  rec=$(make_case annotated-tag "$id")
  read_case_record "$rec"
  tag_commit=$(publish_tag v9.9.9 annotated)
  meta="$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id" --scout --base v9.9.9)
  status=$?
  expect_code 0 "$status" "a scout spawn should accept an annotated tag published on origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tag_commit" ] \
    || fail "an annotated tag base did not cut the worktree from the tag's commit"
  grep -qx "base_commit=$tag_commit" "$meta" \
    || fail "metadata recorded something other than the commit the worktree was cut from"
  [ "$(git -C "$POOL_DIR" rev-parse v9.9.9)" != "$tag_commit" ] \
    || fail "fixture did not produce a real annotated tag object"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed annotated tag base: %s (tag object %s)\n' \
      "$tag_commit" "$(git -C "$POOL_DIR" rev-parse v9.9.9)"
  fi
  pass "an annotated tag base records the commit the worktree was cut from, not the tag object"
}

test_tag_missing_locally_is_fetched_from_origin() {
  local rec id out status tag_sha meta
  id='pool-unfetched-tag-r19'
  rec=$(make_case unfetched-tag "$id")
  read_case_record "$rec"
  tag_sha=$(publish_unreachable_tag release-cut off-branch.txt)
  meta="$HOME_DIR/state/$id.meta"
  [ -z "$(git -C "$POOL_DIR" rev-parse --verify --quiet release-cut 2>/dev/null || true)" ] \
    || fail "fixture did not produce a tag the pooled worktree is missing"

  out=$(run_spawn "$id" --scout --base release-cut)
  status=$?
  expect_code 0 "$status" "a base tag published on origin should be fetched rather than refused"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tag_sha" ] \
    || fail "the fetched tag base did not cut the worktree from the tag's commit"
  [ -f "$POOL_DIR/off-branch.txt" ] \
    || fail "the worktree is missing content that only the requested tag carries"
  grep -qx 'base=release-cut' "$meta" || fail "metadata did not record the fetched tag base"
  pass "a base tag origin publishes but the worktree lacks is fetched by name"
}

test_unresolvable_base_is_reported_as_missing_not_stale() {
  local rec id out status before
  id='pool-missing-base-r20'
  rec=$(make_case missing-base "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --scout --base v1.2.4)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a base that exists nowhere"
  assert_contains "$out" "is not a tag on origin" \
    "spawn did not report a missing base as missing"
  case "$out" in
    *'resolves through'*) fail "spawn diagnosed a missing base as a stale local ref" ;;
  esac
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a base it could not resolve"
  [ -f "$HOME_DIR/state/$id.meta" ] \
    && fail "spawn recorded metadata for a task it refused to launch"
  pass "a base that resolves nowhere is refused as missing rather than as stale"
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
test_ship_base_must_name_a_branch_on_origin
test_stale_local_branch_base_is_refused
test_scout_base_may_be_a_tag_or_a_commit
test_local_only_base_must_be_the_branch_the_merge_fast_forwards
test_annotated_tag_base_records_the_commit_it_cut
test_tag_missing_locally_is_fetched_from_origin
test_unresolvable_base_is_reported_as_missing_not_stale

echo "# all fm-spawn-pool-base-freshen tests passed"
