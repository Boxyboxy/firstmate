#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo fast-forwards from origin on its default branch,
#     or advances only a free default-branch ref while staying on another branch.
#     A leased secondmate home (detached HEAD on the default branch) fast-forwards
#     the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or unsafe target is skipped
#     and reported, never forced or stashed, so unlanded work survives. An
#     off-default checkout never moves its HEAD, index, or working tree.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}


UPDATE="$ROOT/bin/fm-update.sh"
OMP_UPDATE="$ROOT/bin/fm-omp-update.sh"


# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch advances only free main ref -----
test_firstmate_wrong_branch_ref_update() {
  local w out before_head before_status
  w=$(new_world t9)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q -b feature/wip
  before_head=$(git -C "$w/main" rev-parse HEAD)
  printf 'local work\n' > "$w/main/local-work.txt"
  before_status=$(git -C "$w/main" status --porcelain)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: advanced main ref " "off-default firstmate advances the free default ref"
  assert_contains "$out" "checkout stayed on feature/wip" "ref-only update reports the unchanged checkout"
  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" \
    "an advanced ref still reports the off-default checkout that needs repair"
  assert_contains "$out" "reread-firstmate: no" "ref-only update does not request a reread"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before_head" ] \
    || fail "off-default firstmate HEAD moved"
  [ "$(git -C "$w/main" rev-parse main)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "default branch ref did not advance"
  [ "$(git -C "$w/main" status --porcelain)" = "$before_status" ] \
    || fail "off-default working tree changed"
  [ -f "$w/main/local-work.txt" ] || fail "off-default working tree file disappeared"
  pass "T9 firstmate off its default branch advances only the free default ref"
}

test_firstmate_off_branch_diverged_default_ref_skipped() {
  local w out before_main
  w=$(new_world t10)
  printf 'local main work\n' >> "$w/main/README.md"
  git -C "$w/main" add README.md
  git -C "$w/main" commit -qm local-main
  before_main=$(git -C "$w/main" rev-parse main)
  git -C "$w/main" checkout -q -b feature/wip
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: main diverged from origin/main" \
    "diverged off-default default ref is skipped"
  assert_contains "$out" "checkout stayed on feature/wip" \
    "diverged ref skip reports the unchanged checkout"
  [ "$(git -C "$w/main" rev-parse main)" = "$before_main" ] \
    || fail "diverged default ref moved"
  pass "T10 diverged off-default default ref is refused"
}

test_firstmate_off_branch_default_ref_in_other_worktree_skipped() {
  local w out before_main before_holder
  w=$(new_world t11)
  git -C "$w/main" checkout -q -b feature/wip
  git -C "$w/main" worktree add -q "$w/main-holder" main
  before_main=$(git -C "$w/main" rev-parse main)
  before_holder=$(git -C "$w/main-holder" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: main is checked out in another worktree" \
    "default ref checked out elsewhere is skipped"
  [ "$(git -C "$w/main" rev-parse main)" = "$before_main" ] \
    || fail "default ref checked out elsewhere moved"
  [ "$(git -C "$w/main-holder" rev-parse HEAD)" = "$before_holder" ] \
    || fail "other worktree HEAD moved"
  pass "T11 default ref checked out in another worktree is left alone"
}

# A worktree paused mid-rebase on the default branch reports a DETACHED head in
# the worktree inventory, yet git still refuses to force-update that branch and
# the rebase's own completion or --abort would rewrite the ref. update-ref's
# compare-and-swap does not carry that protection, so the ref must stay put.
test_firstmate_off_branch_default_ref_held_by_rebase_skipped() {
  local w out before_main holder_gitdir
  w=$(new_world t11b)
  # main gets a commit that conflicts with branch `conflict`, and origin keeps
  # that commit, so main stays a strict fast-forward candidate throughout.
  git -C "$w/main" checkout -q -b conflict
  printf 'theirs\n' > "$w/main/README.md"
  git -C "$w/main" commit -qam theirs
  git -C "$w/main" checkout -q main
  printf 'ours\n' > "$w/main/README.md"
  git -C "$w/main" commit -qam ours
  git -C "$w/main" push -q origin main
  git -C "$w/main" checkout -q -b feature/wip
  git -C "$w/main" worktree add -q "$w/main-holder" main
  # The conflicting rebase leaves the holder detached with main as its head-name,
  # while refs/heads/main stays exactly where it was.
  git -C "$w/main-holder" rebase conflict >/dev/null 2>&1 && fail "fixture rebase did not conflict"
  git -C "$w/main-holder" symbolic-ref -q HEAD >/dev/null \
    && fail "fixture rebase left the holder on a branch, not detached"
  holder_gitdir=$(git -C "$w/main-holder" rev-parse --absolute-git-dir)
  [ "$(cat "$holder_gitdir/rebase-merge/head-name" 2>/dev/null)" = refs/heads/main ] \
    || fail "fixture rebase does not name refs/heads/main"
  before_main=$(git -C "$w/main" rev-parse main)
  bump_origin "$w" instr
  git -C "$w/main" fetch -q origin
  git -C "$w/main" merge-base --is-ancestor main origin/main \
    || fail "fixture left main unable to fast-forward"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: main is checked out in another worktree" \
    "a default ref held by an interrupted rebase is skipped"
  [ "$(git -C "$w/main" rev-parse main)" = "$before_main" ] \
    || fail "default ref moved under an interrupted rebase"
  pass "T11b default ref held by an interrupted rebase is left alone"
}

make_fake_omp() {
  local case_dir=$1 channel_a channel_b
  channel_a="$case_dir/channel-a"
  channel_b="$case_dir/channel-b"
  mkdir -p "$channel_a" "$channel_b" "$case_dir/home/state"
  for channel in "$channel_a" "$channel_b"; do
    cat > "$channel/omp" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  cat "${OMP_FAKE_VERSION_FILE:?}"
  exit 0
fi
case "${1:-}" in
  update)
    if [ "${2:-}" = --check ]; then
      : > "${OMP_FAKE_CHECK_MARKER:?}"
      printf '%s\n' 'check only'
    else
      : > "${OMP_FAKE_INSTALL_MARKER:?}"
      printf '%s\n' 'installed'
      printf '%s\n' 'omp/99.1.0' > "${OMP_FAKE_VERSION_FILE:?}"
    fi
    ;;
esac
SH
    chmod +x "$channel/omp"
  done
  printf '%s|%s|%s\n' "$case_dir/home" "$channel_a" "$channel_b"
}

test_omp_update_is_guarded_and_channel_preserving() {
  local case_dir="$TMP_ROOT/omp-update" fixture home channel_a channel_b out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  fixture=${fixture#*|}
  channel_a=${fixture%%|*}
  channel_b=${fixture#*|}
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"

  out=$(PATH="$channel_a:$channel_b:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE")

  assert_contains "$out" "omp: channel: $channel_a/omp" "omp update uses the first channel on PATH, as the shell would"
  assert_contains "$out" "omp: before: omp/17.2.6" "omp update reports its starting version"
  assert_contains "$out" "omp: after: omp/99.1.0" "omp update reports its ending version"
  [ -f "$case_dir/install-marker" ] || fail "empty-fleet omp update did not run"
  [ ! -f "$case_dir/check-marker" ] || fail "normal omp update unexpectedly ran check mode"
  pass "omp update is allowed for an empty fleet and preserves the resolved channel"
}
test_omp_update_refuses_live_fleet() {
  local case_dir="$TMP_ROOT/omp-live" fixture home channels channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channels=${fixture#*|}
  channel_a=${channels%%|*}
  make_alive_endpoint_tmux "$case_dir/fakebin"
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  printf 'window=main:win\n' > "$home/state/live.meta"

  if out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "omp update succeeded with a live fleet"
  fi
  assert_contains "$out" "omp: refused: a worker is still running (task live)" \
    "a verifiably running endpoint blocks the swap and is named as a task"
  [ ! -f "$case_dir/install-marker" ] || fail "live-fleet guard attempted an install"
  [ "$(cat "$case_dir/version")" = "omp/17.2.6" ] || fail "live-fleet guard changed omp version"
  pass "omp update refuses a running worker without invoking the updater"
}

# An endpoint whose state cannot be classified at all - an experimental backend
# with no recovery-grade classifier, or a record with no endpoint - must not be
# reported as a running worker, and must not wedge the update with no way out.
test_omp_update_separates_unclassifiable_state_and_honours_force() {
  local case_dir="$TMP_ROOT/omp-unclassified" fixture home channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  {
    printf 'backend=orca\n'
    printf 'terminal=t1\n'
  } > "$home/state/exp.meta"

  if out=$(PATH="$channel_a:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "omp update ran with an unclassifiable endpoint"
  fi
  assert_contains "$out" "omp: refused: could not confirm every worker has stopped (task exp: its orca endpoint reads unverified)" \
    "an unclassifiable endpoint is reported as unconfirmed, not as a running worker"
  assert_contains "$out" "rerun with --force" "the refusal names the operator's way through"
  [ ! -f "$case_dir/install-marker" ] || fail "unclassifiable endpoint still attempted an install"

  out=$(PATH="$channel_a:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" --force 2>&1)
  assert_contains "$out" "omp: forced past a worker whose state could not be confirmed (task exp" \
    "the override says exactly what it overrode"
  assert_contains "$out" "omp: after: omp/99.1.0" "the override completes the update"
  [ -f "$case_dir/install-marker" ] || fail "--force did not run the update"

  if PATH="$channel_a:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" --check --force >/dev/null 2>&1; then
    fail "--check accepted a meaningless --force"
  fi
  pass "omp separates an unclassifiable endpoint from a running one and offers an override"
}

# A tmux that answers every window inventory with the definitive missing-session
# response, so fm_backend_agent_state classifies the recorded endpoint `missing`.
make_dead_endpoint_tmux() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  printf "can't find session: %s\n" "${3:-}" >&2
fi
exit 1
SH
  chmod +x "$dir/tmux"
}

# A tmux whose inventory names window `win` and whose pane runs a verified
# harness, so fm_backend_agent_state classifies that endpoint `alive`.
make_alive_endpoint_tmux() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *pane_current_command*) printf '%s\n' claude; exit 0 ;; esac
    done
    exit 0
    ;;
  list-windows) printf '%s\n' win; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/tmux"
}

# A stale record left by an interrupted cleanup must not wedge omp forever: its
# recorded endpoint is gone, so nothing is running that omp could break.
test_omp_update_ignores_records_whose_endpoint_is_gone() {
  local case_dir="$TMP_ROOT/omp-stale" fixture home channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  make_dead_endpoint_tmux "$case_dir/fakebin"
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  printf 'window=main:fm-gone\n' > "$home/state/gone.meta"

  out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE")

  assert_contains "$out" "omp: after: omp/99.1.0" "stale record does not block the update"
  [ -f "$case_dir/install-marker" ] || fail "stale record wedged the omp update"
  pass "omp update ignores a record whose endpoint is authoritatively gone"
}

# A persistent second mate is never a backlog task, so the refusal must not call
# it one - and its record only blocks while its endpoint is actually running.
test_omp_update_names_a_second_mate_correctly() {
  local case_dir="$TMP_ROOT/omp-sm" fixture home channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  make_dead_endpoint_tmux "$case_dir/fakebin"
  make_alive_endpoint_tmux "$case_dir/alivebin"
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  {
    printf 'kind=secondmate\n'
    printf 'home=%s/sm\n' "$case_dir"
    printf 'window=main:win\n'
  } > "$home/state/sm1.meta"

  if out=$(PATH="$channel_a:$case_dir/alivebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "omp update succeeded with a running second mate"
  fi
  assert_contains "$out" "omp: refused: a worker is still running (second mate sm1)" \
    "a persistent second mate is never reported as a task"
  [ ! -f "$case_dir/install-marker" ] || fail "running second mate did not stop the install"

  # The same record stops blocking once its endpoint is authoritatively gone.
  {
    printf 'kind=secondmate\n'
    printf 'home=%s/sm\n' "$case_dir"
    printf 'window=main:fm-sm1\n'
  } > "$home/state/sm1.meta"
  out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE")
  assert_contains "$out" "omp: after: omp/99.1.0" "a second mate that is not running does not wedge omp"
  [ -f "$case_dir/install-marker" ] || fail "non-running second mate wedged the omp update"
  pass "omp names a second mate correctly and only blocks while it is running"
}

# omp is one machine-wide executable, so a second mate's OWN crewmates are just
# as breakable as this home's. Their records live in that second mate's isolated
# home, which the gate has to reach through both the live record and the registry.
test_omp_update_covers_second_mate_homes() {
  local case_dir="$TMP_ROOT/omp-sm-home" fixture home channel_a sm_home out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  make_alive_endpoint_tmux "$case_dir/alivebin"
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  sm_home="$case_dir/sm-home"
  mkdir -p "$sm_home/state"
  printf 'window=main:win\n' > "$sm_home/state/busy.meta"
  # This home's own record carries no endpoint, so only the second mate home's
  # crewmate can supply the running verdict the refusal must report.
  {
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm_home"
  } > "$home/state/sm1.meta"

  if out=$(PATH="$channel_a:$case_dir/alivebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "omp update swapped the executable under a second mate's crewmate"
  fi
  assert_contains "$out" "omp: refused: a worker is still running (task busy in second mate sm1's home)" \
    "a second mate home's running crewmate blocks the swap and is located"
  [ ! -f "$case_dir/install-marker" ] || fail "second mate home's crewmate did not stop the install"

  # The registry is the same guarantee for a second mate with no live record.
  rm -f "$home/state/sm1.meta"
  mkdir -p "$home/data"
  printf -- '- sm1 - a second mate (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$sm_home" > "$home/data/secondmates.md"
  if out=$(PATH="$channel_a:$case_dir/alivebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "a registry-only second mate home was left unswept"
  fi
  assert_contains "$out" "omp: refused: a worker is still running (task busy in second mate sm1's home)" \
    "the registry reaches a second mate home with no live record"

  # A remote second mate's workers run on another machine, where this machine's
  # omp cannot break them, so its route never blocks the local update.
  rm -f "$sm_home/state/busy.meta"
  printf -- '- sm2 - a remote second mate (host: h1; root: /srv/fm; home: /srv/sm2; scope: y; projects: p; added 2026-06-23)\n' \
    > "$home/data/secondmates.md"
  out=$(PATH="$channel_a:$case_dir/alivebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE")
  assert_contains "$out" "omp: after: omp/99.1.0" "a remote second mate does not block the local channel"
  [ -f "$case_dir/install-marker" ] || fail "remote second mate wedged the local omp update"
  pass "omp accounts for every local second mate home, not just this one"
}

# A tmux whose inventory read fails with an error that proves nothing, so
# fm_backend_agent_state classifies the recorded endpoint `unreadable` - what a
# host with no usable tmux at all answers for any recorded window.
make_unreadable_endpoint_tmux() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux: something unexpected\n' >&2
exit 1
SH
  chmod +x "$dir/tmux"
}

# A remote second mate's worker runs on another machine, so this machine's omp
# cannot break it. Its local record is only a proxy - `window=remote:<id>` with
# no backend field - so classifying it against the LOCAL backend asks about the
# wrong machine and, on a host whose local backend cannot answer, would wedge
# every normal update for a worker that was never at risk.
test_omp_update_ignores_a_remote_second_mate_record() {
  local case_dir="$TMP_ROOT/omp-sm-remote" fixture home channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  make_unreadable_endpoint_tmux "$case_dir/fakebin"
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  {
    printf 'window=remote:sm2\n'
    printf 'kind=secondmate\n'
    printf 'home=/srv/sm2\n'
    printf 'remote_host=h1\n'
    printf 'remote_root=/srv/fm\n'
    printf 'remote_backend=tmux\n'
    printf 'remote_target=main:fm-sm2\n'
  } > "$home/state/sm2.meta"

  out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE")

  assert_contains "$out" "omp: after: omp/99.1.0" "a remote record does not block the local channel"
  [ -f "$case_dir/install-marker" ] || fail "a remote second mate record wedged the local omp update"
  pass "omp never classifies a remote second mate's record against the local backend"
}

# The gate refuses to call an endpoint it cannot classify stopped, so a whole
# home or registry it cannot reach must not be counted as proof of an empty
# fleet either. Both report the place they could not reach and point at --force.
test_omp_update_reports_places_it_cannot_reach() {
  local case_dir="$TMP_ROOT/omp-unreachable" fixture home channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  make_dead_endpoint_tmux "$case_dir/fakebin"
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  # The record's own endpoint is authoritatively gone, so the only thing left
  # unproven is the home its unusable path was supposed to point at.
  {
    printf 'kind=secondmate\n'
    printf 'window=main:fm-sm1\n'
    printf 'home=relative/sm1\n'
  } > "$home/state/sm1.meta"

  if out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "an unreachable second mate home was treated as an empty fleet"
  fi
  assert_contains "$out" "second mate sm1's home: its recorded location is not a usable path (relative/sm1)" \
    "a home the sweep cannot reach is named, not silently dropped"
  assert_contains "$out" "rerun with --force" "the refusal names the operator's way through"
  [ ! -f "$case_dir/install-marker" ] || fail "unreachable home still attempted an install"

  out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" --force 2>&1)
  assert_contains "$out" "omp: after: omp/99.1.0" "the override completes the update"

  # A registry that is not a plain file is the same kind of unproven gap: the
  # whole registered-home backstop went unread.
  rm -f "$home/state/sm1.meta" "$case_dir/install-marker"
  mkdir -p "$home/data"
  printf -- '- sm1 - a second mate (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' \
    "$case_dir" > "$case_dir/registry.md"
  ln -s "$case_dir/registry.md" "$home/data/secondmates.md"
  if out=$(PATH="$channel_a:$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" 2>&1); then
    fail "an unread registry was treated as an empty fleet"
  fi
  assert_contains "$out" "the second mate registry: $home/data/secondmates.md is not a plain file" \
    "an unread registry is reported instead of assumed empty"
  [ ! -f "$case_dir/install-marker" ] || fail "unread registry still attempted an install"
  pass "omp reports every place it could not reach instead of assuming it is empty"
}

test_omp_check_is_detect_only_with_live_fleet() {
  local case_dir="$TMP_ROOT/omp-check" fixture home channel_a out
  fixture=$(make_fake_omp "$case_dir")
  home=${fixture%%|*}
  channel_a=${fixture#*|}
  channel_a=${channel_a%%|*}
  printf '%s\n' 'omp/17.2.6' > "$case_dir/version"
  : > "$home/state/live.meta"

  out=$(PATH="$channel_a:$BASE_PATH" FM_HOME="$home" \
    OMP_FAKE_VERSION_FILE="$case_dir/version" \
    OMP_FAKE_INSTALL_MARKER="$case_dir/install-marker" \
    OMP_FAKE_CHECK_MARKER="$case_dir/check-marker" "$OMP_UPDATE" --check)

  assert_contains "$out" "check only" "omp check runs the channel's check command"
  [ -f "$case_dir/check-marker" ] || fail "omp check did not run check mode"
  [ ! -f "$case_dir/install-marker" ] || fail "omp check attempted an install"
  [ "$(cat "$case_dir/version")" = "omp/17.2.6" ] || fail "omp check changed omp version"
  pass "omp check remains detect-only even with a live fleet"
}


# A linked-worktree secondmate home shares its ref store with the whole repo, so
# an off-branch ref advance there moves the PRIMARY's default branch, not
# anything private to that home. Reachable whenever the primary itself holds no
# default-branch checkout, so the report must name the repository it moved.
test_off_branch_ref_advance_names_the_shared_repo() {
  local w out before_main shared
  w=$(new_world t14)
  git -C "$w/main" worktree add -q -b sm/wip "$w/sm1" main
  printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
  {
    printf 'window=main:fm-sm1\n'
    printf 'kind=secondmate\n'
    printf 'home=%s/sm1\n' "$w"
  } > "$w/home/state/sm1.meta"
  git -C "$w/main" checkout -q --detach HEAD
  before_main=$(git -C "$w/main" rev-parse main)
  bump_origin "$w" instr
  shared=$(cd "$w/main" && pwd -P)

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: on sm/wip, expected main" \
    "the off-branch home stays visible as a repair"
  assert_contains "$out" "advanced main ref (shared with $shared)" \
    "the ref advance names the repository whose branch actually moved"
  [ "$(git -C "$w/main" rev-parse main)" != "$before_main" ] \
    || fail "the free shared default ref did not advance"
  [ "$(git -C "$w/sm1" rev-parse --abbrev-ref HEAD)" = "sm/wip" ] \
    || fail "the off-branch home's checkout moved"
  pass "T14 a shared default ref advance names the repository it moved"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t12)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T12 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t13)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T13 unsafe secondmate home is not fast-forwarded"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_ref_update
test_firstmate_off_branch_diverged_default_ref_skipped
test_firstmate_off_branch_default_ref_in_other_worktree_skipped
test_firstmate_off_branch_default_ref_held_by_rebase_skipped
test_off_branch_ref_advance_names_the_shared_repo
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_omp_update_is_guarded_and_channel_preserving
test_omp_update_refuses_live_fleet
test_omp_update_separates_unclassifiable_state_and_honours_force
test_omp_update_ignores_records_whose_endpoint_is_gone
test_omp_update_names_a_second_mate_correctly
test_omp_update_covers_second_mate_homes
test_omp_update_ignores_a_remote_second_mate_record
test_omp_update_reports_places_it_cannot_reach
test_omp_check_is_detect_only_with_live_fleet

echo "# all fm-update tests passed"
