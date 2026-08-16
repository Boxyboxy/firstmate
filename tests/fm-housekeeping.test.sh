#!/usr/bin/env bash
# Behavioral regressions for fm-housekeeping's protection logic.
#
# The case this suite exists for is the first one: a name filter that matches
# nothing must produce an EMPTY kill-list, never a match-everything one. The
# fake docker below reproduces the real degradation that caused the incident -
# `docker ps -q --format ...` ignores the format and emits container IDs - so
# the test drives that failure mode rather than assuming it away.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOUSEKEEPING="$ROOT/bin/fm-housekeeping.sh"
TMP_ROOT=$(fm_test_tmproot fm-housekeeping)

# --- fixture helpers ---------------------------------------------------------

# fm_hk_fakes <dir>: install fake docker and treehouse into <dir>/fakebin and
# echo that directory. The fakes read their fixture and log paths from the
# environment, so each case points them at its own files.
fm_hk_fakes() {
  local bin
  bin=$(fm_fakebin "$1")
  cat >"$bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_DOCKER_LOG"
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  ps)
    q=0; fmt=0; all=0
    for a in "$@"; do
      case "$a" in
        -q|--quiet) q=1 ;;
        --format) fmt=1 ;;
        -a|--all) all=1 ;;
      esac
    done
    if [ "$q" = 1 ] && [ "$fmt" = 1 ]; then
      # Real docker behavior when both flags are set.
      echo 'WARNING: Ignoring custom format, because both --format and --quiet are set.' >&2
      awk -F'|' -v all="$all" 'all==1 || $2=="running" {printf "%012x\n", NR*48879}' \
        "$FM_TEST_DOCKER_FIXTURE"
      exit 0
    fi
    if [ -s "$FM_TEST_CONTAINER_LATE_LIVE" ]; then
      IFS='|' read -r late_id late_sample <"$FM_TEST_CONTAINER_LATE_LIVE"
      current_sample=$(cat "$FM_TEST_CONTAINER_SAMPLE_COUNT")
      if [ "$current_sample" -ge "$late_sample" ] && [ ! -e "$FM_HOME/state/$late_id.meta" ]; then
        printf 'kind=ship\nworktree=/pool/%s\n' "$late_id" >"$FM_HOME/state/$late_id.meta"
      fi
    fi
    if [ "$all" = 1 ]; then
      count=$(cat "$FM_TEST_CONTAINER_SAMPLE_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" >"$FM_TEST_CONTAINER_SAMPLE_COUNT"
      sample="$FM_TEST_CONTAINER_SAMPLE_DIR/$count"
      if [ -f "$sample" ]; then
        cat "$sample"
      else
        cat "$FM_TEST_DOCKER_FIXTURE"
      fi
    else
      late_active=0
      if [ -n "${late_id:-}" ] && [ -e "$FM_HOME/state/$late_id.meta" ]; then
        late_active=1
      fi
      awk -F'|' -v stopped_file="$FM_TEST_CONTAINER_STOP_AFTER_LATE" -v late_active="$late_active" '
        BEGIN {
          while ((getline stopped < stopped_file) > 0) stop[stopped] = 1
          close(stopped_file)
        }
        $2 == "running" && !(late_active && ($1 in stop)) { print $1 }
      ' "$FM_TEST_DOCKER_FIXTURE"
    fi
    ;;
  inspect)
    name="${@: -1}"
    awk -F'|' -v name="$name" '$1 == name {print $2}' "$FM_TEST_CONTAINER_MOUNTS"
    ;;
  rm)
    for a in "$@"; do
      case "$a" in -*) ;; *) printf '%s\n' "$a" >>"$FM_TEST_DOCKER_RM" ;; esac
    done
    ;;
  system) printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\n' ;;
  volume)
    subcmd="${1:-}"; shift 2>/dev/null || true
    case "$subcmd" in
      ls)
        dangling=0; label_key=''; label_val=''; label_has_val=0
        for a in "$@"; do
          [ "$a" = dangling=true ] && dangling=1
          case "$a" in
            label=*)
              label_key="${a#label=}"
              case "$label_key" in
                *=*)
                  label_val="${label_key#*=}"
                  label_key="${label_key%%=*}"
                  label_has_val=1
                  ;;
              esac
              ;;
          esac
        done
        # Model docker's own label filter: it selects only volumes carrying that
        # label key (and value, when one is given). An unrecognized key matches
        # NOTHING. A permissive fallback here would let a protection check that
        # silently matches nothing still pass its test, which is the exact bug
        # this suite exists to catch.
        fake_volume_has_label() {
          awk -F'|' -v name="$1" -v k="$label_key" -v v="$label_val" -v hv="$label_has_val" '
            $1 == name && $2 == k { if (hv == 0 || $3 == v) found = 1 }
            END { exit !found }
          ' "$FM_TEST_VOLUME_METADATA"
        }
        if [ "$dangling" = 1 ]; then
          count=$(cat "$FM_TEST_VOLUME_SAMPLE_COUNT")
          count=$((count + 1))
          printf '%s\n' "$count" >"$FM_TEST_VOLUME_SAMPLE_COUNT"
          sample="$FM_TEST_VOLUME_SAMPLE_DIR/$count"
          [ -f "$sample" ] || exit 0
          if [ -n "$label_key" ]; then
            while IFS= read -r name; do
              fake_volume_has_label "$name" && printf '%s\n' "$name"
            done <"$sample"
          else
            cat "$sample"
          fi
        elif [ -n "$label_key" ]; then
          awk -F'|' -v k="$label_key" -v v="$label_val" -v hv="$label_has_val" \
            '$2 == k { if (hv == 0 || $3 == v) print $1 }' "$FM_TEST_VOLUME_METADATA"
        fi
        ;;
      rm)
        printf '%s\n' "$@" >>"$FM_TEST_VOLUME_RM"
        ;;
      inspect)
        name="${@: -1}"
        awk -F'|' -v name="$name" '$1 == name {print $2}' "$FM_TEST_VOLUME_METADATA"
        ;;
    esac
    ;;
  builder|image) printf 'Total reclaimed space: 0B\n' ;;
esac
exit 0
FAKE
  cat >"$bin/treehouse" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_TREEHOUSE_LOG"
cat <<'OUT'
No stale worktrees to prune across 3 pools.
Skipped 1 unsafe idle worktree:
  uncommitted changes:
  18    /pool/18/demo
OUT
[ -f "$FM_TEST_TREEHOUSE_CANDIDATE" ] && cat "$FM_TEST_TREEHOUSE_CANDIDATE"
if case " $* " in *' --yes '*) true ;; *) false ;; esac &&
  [ -s "$FM_TEST_TREEHOUSE_LATE_LIVE" ]; then
  while IFS='|' read -r id worktree; do
    printf 'kind=ship\nworktree=%s\n' "$worktree" >"$FM_HOME/state/$id.meta"
    rmdir "$worktree"
  done <"$FM_TEST_TREEHOUSE_LATE_LIVE"
fi
FAKE
  chmod +x "$bin/docker" "$bin/treehouse"
  printf '%s\n' "$bin"
}

# fm_hk_case <name>: build an isolated case directory with a firstmate home and
# empty logs, then echo the case directory. Everything the fakes need is derived
# from that path by fm_hk_run, because this function runs in a command
# substitution and cannot export into its caller.
fm_hk_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  : >"$dir/docker.log"
  : >"$dir/docker.rm"
  : >"$dir/treehouse.log"
  : >"$dir/treehouse.candidate"
  : >"$dir/treehouse.late-live"
  : >"$dir/containers"
  : >"$dir/volume.rm"
  : >"$dir/container-mounts"
  : >"$dir/container.late-live"
  : >"$dir/container.stop-after-late"
  : >"$dir/volume-metadata"
  printf '0\n' >"$dir/container-sample-count"
  mkdir -p "$dir/container-samples"
  printf '0\n' >"$dir/volume-sample-count"
  mkdir -p "$dir/volume-samples"
  printf '%s\n' "$dir"
}

# fm_hk_container <dir> <name> <state> <project> <task> <ports> <workdir>
fm_hk_container() {
  printf '%s|%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >>"$1/containers"
}

fm_hk_run() { # <dir> <args...>
  local dir="$1"; shift
  local bin; bin=$(fm_hk_fakes "$dir")
  PATH="$bin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_DOCKER_LOG="$dir/docker.log" FM_TEST_DOCKER_RM="$dir/docker.rm" \
    FM_TEST_DOCKER_FIXTURE="$dir/containers" FM_TEST_TREEHOUSE_LOG="$dir/treehouse.log" \
    FM_TEST_TREEHOUSE_CANDIDATE="$dir/treehouse.candidate" \
    FM_TEST_TREEHOUSE_LATE_LIVE="$dir/treehouse.late-live" \
    FM_TEST_VOLUME_RM="$dir/volume.rm" \
    FM_TEST_VOLUME_SAMPLE_COUNT="$dir/volume-sample-count" \
    FM_TEST_VOLUME_SAMPLE_DIR="$dir/volume-samples" \
    FM_TEST_CONTAINER_MOUNTS="$dir/container-mounts" \
    FM_TEST_CONTAINER_SAMPLE_COUNT="$dir/container-sample-count" \
    FM_TEST_CONTAINER_SAMPLE_DIR="$dir/container-samples" \
    FM_TEST_CONTAINER_LATE_LIVE="$dir/container.late-live" \
    FM_TEST_CONTAINER_STOP_AFTER_LATE="$dir/container.stop-after-late" \
    FM_TEST_VOLUME_METADATA="$dir/volume-metadata" \
    FM_HOUSEKEEPING_VOLUME_STABILITY_SECONDS=0 \
    "$HOUSEKEEPING" "$@" >"$dir/out" 2>"$dir/err"
}

# Every apply path must satisfy this: nothing the run reported as kept may ever
# be handed to `docker rm`.
assert_no_kept_name_removed() { # <dir>
  local dir="$1" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -qxF "$name" "$dir/docker.rm" 2>/dev/null; then
      fail "removed $name after reporting it as kept"
    fi
  done < <(awk '$1 == "keep" {print $2}' "$dir/out")
}

# --- cases -------------------------------------------------------------------

test_unattributable_fleet_yields_empty_kill_list() {
  local dir i code
  dir=$(fm_hk_case unattributable)
  # The captain's live stack plus sixteen more running containers, none of them
  # attributable to any firstmate task: exactly the shape of the real sweep.
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  for i in $(seq 1 16); do
    fm_hk_container "$dir" "misc-$i" running '' '' '' ''
  done

  fm_hk_run "$dir" --apply --no-worktrees
  code=$?
  expect_code 0 "$code" 'apply over an unattributable fleet'

  if [ -s "$dir/docker.rm" ]; then
    fail "removed containers it could not attribute: $(tr '\n' ' ' <"$dir/docker.rm")"
  fi
  assert_grep 'keep    wffui-pg' "$dir/out" \
    'the live captain stack was not reported as kept'
  assert_grep 'running with a bound host port' "$dir/out" \
    'a bound host port did not register as the in-use signal'
  assert_grep 'running and unattributable' "$dir/out" \
    'unattributable containers were not reported for the captain'

  # The listing itself must never ask docker for a format it will discard.
  if grep -e '-q' "$dir/docker.log" | grep -q -e '--format'; then
    fail 'combined -q with --format, the flag pair that silently emits IDs'
  fi
  pass 'a fleet it cannot attribute yields an empty kill-list, not an empty filter'
}

test_degraded_id_listing_still_reclaims_nothing() {
  local dir
  dir=$(fm_hk_case degraded)
  # Simulate the degraded output itself: opaque IDs where names were expected.
  # A name filter matches none of them, and the kill-list must stay empty.
  mkdir -p "$dir/home/data/gone-task"
  fm_hk_container "$dir" 4f1b26387088 running '' '' '127.0.0.1:8131->8131/tcp' ''
  fm_hk_container "$dir" 9ac31d0f1122 running '' '' '' ''
  fm_hk_container "$dir" 22b7714cc901 exited '' '' '' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply over an ID-shaped listing'

  if grep -qxF 4f1b26387088 "$dir/docker.rm" 2>/dev/null ||
    grep -qxF 9ac31d0f1122 "$dir/docker.rm" 2>/dev/null; then
    fail 'removed a running container that matched no task id'
  fi
  assert_no_kept_name_removed "$dir"
  pass 'opaque identifiers match no task and are kept, never swept'
}

test_refuses_a_listing_it_cannot_parse() {
  local dir code
  dir=$(fm_hk_case malformed)
  # The raw shape of the incident: the listing lost its fields and is nothing
  # but container IDs. Nothing here can be classified, so nothing may be swept.
  mkdir -p "$dir/home/data/gone-task"
  printf '%s\n' 4f1b26387088 9ac31d0f1122 22b7714cc901 >"$dir/containers"

  fm_hk_run "$dir" --apply --no-worktrees
  code=$?
  expect_code 3 "$code" 'apply over a listing with no fields'
  if [ -s "$dir/docker.rm" ]; then
    fail "swept a listing it could not parse: $(tr '\n' ' ' <"$dir/docker.rm")"
  fi
  assert_grep 'not in the expected shape' "$dir/err" \
    'the refusal did not name the unreadable listing'

  fm_hk_run "$dir" --no-worktrees
  expect_code 0 "$?" 'dry run over a listing with no fields'
  assert_grep 'Every container is kept' "$dir/out" \
    'the dry run did not report the unreadable listing as keeping everything'
  pass 'a listing it cannot parse keeps everything and refuses the delete path'
}

test_orphan_removed_while_live_task_and_stack_are_kept() {
  local dir
  dir=$(fm_hk_case orphan)
  mkdir -p "$dir/home/data/live-alpha" "$dir/home/data/gone-beta"
  fm_write_meta "$dir/home/state/live-alpha.meta" 'kind=ship' 'worktree=/pool/live-alpha'
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  fm_hk_container "$dir" fm-live-alpha-db running '' '' '' ''
  fm_hk_container "$dir" fm-gone-beta-db running '' '' '' ''
  fm_hk_container "$dir" fm-gone-beta-api exited '' '' '' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with one finished task'

  assert_grep fm-gone-beta-db "$dir/docker.rm" \
    'the orphaned container of a finished task survived the sweep'
  assert_no_grep fm-live-alpha-db "$dir/docker.rm" \
    'removed a container owned by a live task'
  assert_no_grep wffui-pg "$dir/docker.rm" \
    'removed the serving captain stack'
  assert_no_kept_name_removed "$dir"
  pass 'a finished task loses its containers while live work and live stacks keep theirs'
}

test_orphan_that_becomes_live_before_removal_is_kept() {
  local dir code
  dir=$(fm_hk_case late-live-container)
  mkdir -p "$dir/home/data/gone-beta"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  fm_hk_container "$dir" fm-gone-beta-db running '' '' '' ''
  printf 'gone-beta|1\n' >"$dir/container.late-live"
  printf 'fm-gone-beta-db\n' >"$dir/container.stop-after-late"

  fm_hk_run "$dir" --apply --no-worktrees
  code=$?
  expect_code 1 "$code" 'apply when a late-protected orphan stops before verification'
  assert_no_grep fm-gone-beta-db "$dir/docker.rm" \
    'removed an orphan whose owning task became live before removal'
  assert_grep 'became protected before removal' "$dir/out" \
    'the late live-task protection was not reported'
  assert_grep 'FAILED: protected container fm-gone-beta-db is no longer running' "$dir/out" \
    'final verification omitted a container protected only by the late check'
  assert_no_grep 'every protected container is still running' "$dir/out" \
    'verification passed after a late-protected container stopped'
  pass 'a late-protected orphan is included in final verification'
}

test_finished_task_name_with_bound_port_is_kept() {
  local dir
  dir=$(fm_hk_case serving-orphan)
  mkdir -p "$dir/home/data/gone-beta"
  fm_hk_container "$dir" fm-gone-beta-api running '' '' '127.0.0.1:3000->3000/tcp' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with a serving container named for a finished task'
  assert_no_grep fm-gone-beta-api "$dir/docker.rm" \
    'removed a structurally protected container attributed to finished work'
  assert_grep 'running with a bound host port' "$dir/out" \
    'structural protection did not precede finished-task attribution'
  pass 'a bound host port protects a container named for finished work'
}

test_refuses_when_nothing_running_would_be_kept() {
  local dir code
  dir=$(fm_hk_case sweep-everything)
  mkdir -p "$dir/home/data/gone-one" "$dir/home/data/gone-two"
  fm_hk_container "$dir" fm-gone-one-db running '' '' '' ''
  fm_hk_container "$dir" fm-gone-two-db running '' '' '' ''

  fm_hk_run "$dir" --apply --no-worktrees
  code=$?
  expect_code 3 "$code" 'apply that would remove every running container'
  if [ -s "$dir/docker.rm" ]; then
    fail 'deleted despite refusing the run'
  fi
  assert_grep 'REFUSED' "$dir/err" 'the refusal was not reported'
  pass 'a sweep that would keep no running container refuses instead'
}

test_refuses_when_a_name_lands_on_both_lists() {
  local dir code
  dir=$(fm_hk_case both-lists)
  mkdir -p "$dir/home/data/gone-beta"
  # An inconsistent inventory: the same name classified both ways. The name-wise
  # assert before deletion must stop the whole run.
  fm_hk_container "$dir" shared-name running '' '' '127.0.0.1:9000->9000/tcp' ''
  fm_hk_container "$dir" shared-name running '' 'gone-beta' '' ''
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply --no-worktrees
  code=$?
  expect_code 3 "$code" 'apply with a name on both lists'
  if [ -s "$dir/docker.rm" ]; then
    fail 'deleted a name that was also on the keep-list'
  fi
  assert_grep 'shared-name' "$dir/err" 'the colliding name was not named in the refusal'
  pass 'a name on both lists refuses the run by name, before any deletion'
}

test_configured_keep_and_stack_project_protect_stopped_members() {
  local dir stack
  dir=$(fm_hk_case keep-list)
  stack="$dir/stack"
  mkdir -p "$stack"
  printf 'docker run --name pinned-db postgres\n' >"$stack/stack.sh"
  printf '%s\n' 'reserved-*' "$stack" >"$dir/home/config/housekeeping-keep"
  mkdir -p "$dir/home/data/gone-beta"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  fm_hk_container "$dir" reserved-cache exited '' '' '' ''
  fm_hk_container "$dir" pinned-db exited '' '' '' ''
  fm_hk_container "$dir" web-api running webstack '' '127.0.0.1:3000->3000/tcp' ''
  fm_hk_container "$dir" web-worker exited webstack '' '' ''
  fm_hk_container "$dir" web-orphan exited webstack gone-beta '' ''
  fm_hk_container "$dir" junk-cache exited '' '' '' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with a configured keep-list'

  assert_no_grep reserved-cache "$dir/docker.rm" 'removed a configured keep-list prefix match'
  assert_no_grep pinned-db "$dir/docker.rm" 'removed a container a stack manifest claims'
  assert_no_grep web-worker "$dir/docker.rm" 'removed a stopped member of a live stack'
  assert_no_grep web-orphan "$dir/docker.rm" \
    'removed a stopped finished-task container from a protected project'
  assert_grep junk-cache "$dir/docker.rm" 'left an unclaimed stopped container behind'
  assert_no_kept_name_removed "$dir"
  pass 'the keep-list, stack manifests, and live projects protect stopped members'
}

test_worktree_phase_never_overrides_the_uncommitted_refusal() {
  local dir
  dir=$(fm_hk_case worktrees)
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir"
  expect_code 0 "$?" 'worktree dry run'
  assert_no_grep '--yes' "$dir/treehouse.log" 'the dry run asked treehouse to delete'
  assert_grep 'unlanded work' "$dir/out" 'skipped worktrees were not flagged as unlanded work'

  : >"$dir/treehouse.log"
  fm_hk_run "$dir" --apply
  expect_code 0 "$?" 'worktree apply'
  assert_grep '--all --yes' "$dir/treehouse.log" 'apply did not authorize the prune'
  assert_no_grep '--prune-orphans' "$dir/treehouse.log" \
    'apply passed --prune-orphans, which deletes unverified candidates'
  pass 'worktree pruning never overrides treehouse refusals and never chases orphans'
}

test_live_task_worktree_is_refused_before_pruning() {
  local dir live_worktree code
  dir=$(fm_hk_case live-worktree)
  live_worktree="$dir/live-worktree"
  mkdir -p "$live_worktree"
  fm_write_meta "$dir/home/state/live-alpha.meta" 'kind=ship' "worktree=$live_worktree"
  printf 'Would prune 1 stale worktree:\n  18    %s\n' "$live_worktree" >"$dir/treehouse.candidate"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply
  code=$?
  expect_code 3 "$code" 'apply when treehouse proposes a live task worktree'
  assert_grep 'live task worktree' "$dir/err" 'the refusal did not name the live-worktree risk'
  assert_no_grep '--yes' "$dir/treehouse.log" 'authorized pruning after identifying a live worktree'
  [ -d "$live_worktree" ] || fail 'the live task worktree did not survive the prune guard'
  pass 'a clean worktree recorded by live metadata survives pruning'
}

test_skipped_live_worktree_does_not_refuse_apply() {
  local dir live_worktree
  dir=$(fm_hk_case skipped-live-worktree)
  live_worktree="$dir/live-dirty"
  mkdir -p "$live_worktree"
  fm_write_meta "$dir/home/state/live-dirty.meta" 'kind=ship' "worktree=$live_worktree"
  printf 'Skipped 1 unsafe idle worktree:\n  uncommitted changes:\n  18    %s\n' \
    "$live_worktree" >"$dir/treehouse.candidate"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply
  expect_code 0 "$?" 'apply when treehouse reports a skipped live worktree'
  assert_grep '--all --yes' "$dir/treehouse.log" 'a skipped live worktree refused apply'
  [ -d "$live_worktree" ] || fail 'treehouse removed a skipped live worktree'
  pass 'a skipped live worktree does not trigger candidate refusal'
}

test_late_live_worktree_loss_is_reported() {
  local dir live_worktree code
  dir=$(fm_hk_case late-live-worktree)
  live_worktree="$dir/late-live"
  mkdir -p "$live_worktree"
  printf 'late-alpha|%s\n' "$live_worktree" >"$dir/treehouse.late-live"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply
  code=$?
  expect_code 1 "$code" 'apply when a worktree becomes live during pruning'
  assert_grep 'LIVE WORKTREE LOST' "$dir/err" 'the post-prune check missed the lost worktree'
  assert_grep 'task late-alpha' "$dir/err" 'the incident report omitted the owning task id'
  assert_grep "$live_worktree" "$dir/err" 'the incident report omitted the worktree path'
  pass 'a worktree entering the live set during prune is reported if lost'
}

test_stable_anonymous_volume_is_reclaimed() {
  local dir volume
  dir=$(fm_hk_case stable-volume)
  volume=$(printf 'a%.0s' {1..64})
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s\n' "$volume" >"$dir/volume-samples/2"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with a stable dangling anonymous volume'
  assert_grep "$volume" "$dir/volume.rm" 'a stable dangling anonymous volume was kept'
  if grep 'volume ls' "$dir/docker.log" | grep -q -- '-q'; then
    fail 'combined volume --format listing with -q'
  fi
  pass 'a volume dangling at both samples is reclaimed'
}

test_transient_dangling_volume_is_kept() {
  local dir volume
  dir=$(fm_hk_case transient-volume)
  volume=$(printf 'b%.0s' {1..64})
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with a transient dangling anonymous volume'
  assert_no_grep "$volume" "$dir/volume.rm" 'removed a volume absent from the second sample'
  pass 'a volume referenced again by the second sample is kept'
}

test_nonrunning_protected_container_aborts_volume_phase() {
  local dir volume
  dir=$(fm_hk_case guarded-volume)
  volume=$(printf 'c%.0s' {1..64})
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"
  printf '%s\n' pinned-db >"$dir/home/config/housekeeping-keep"
  fm_hk_container "$dir" pinned-db exited '' '' '' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with a non-running protected container'
  assert_no_grep "$volume" "$dir/volume.rm" 'removed a volume while protected work was non-running'
  assert_grep 'protected container pinned-db is not running' "$dir/out" \
    'the volume phase did not explain its safety abort'
  pass 'a non-running protected container aborts volume reclamation'
}

test_live_mount_seen_before_first_sample_stays_protected() {
  local dir volume
  dir=$(fm_hk_case live-mount-before-sample)
  volume=$(printf 'e%.0s' {1..64})
  mkdir -p "$dir/home/data/live-alpha"
  fm_write_meta "$dir/home/state/live-alpha.meta" 'kind=ship' 'worktree=/pool/live-alpha'
  fm_hk_container "$dir" fm-live-alpha-db running '' '' '' ''
  printf 'fm-live-alpha-db|%s\n' "$volume" >"$dir/container-mounts"
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s\n' "$volume" >"$dir/volume-samples/2"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"
  cp "$dir/containers" "$dir/container-samples/2"
  : >"$dir/container-samples/3"
  : >"$dir/container-samples/4"

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply when live work exists only before the first volume sample'
  assert_no_grep "$volume" "$dir/volume.rm" \
    'removed a volume mounted by live work before the first sample'
  pass 'the before-sample observation contributes to protected mounts'
}

test_live_mount_seen_after_first_sample_stays_protected() {
  local dir volume
  dir=$(fm_hk_case live-mount-after-sample)
  volume=$(printf '7%.0s' {1..64})
  mkdir -p "$dir/home/data/live-alpha"
  fm_write_meta "$dir/home/state/live-alpha.meta" 'kind=ship' 'worktree=/pool/live-alpha'
  fm_hk_container "$dir" fm-live-alpha-db running '' '' '' ''
  printf 'fm-live-alpha-db|%s\n' "$volume" >"$dir/container-mounts"
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s\n' "$volume" >"$dir/volume-samples/2"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"
  : >"$dir/container-samples/2"
  cp "$dir/containers" "$dir/container-samples/3"
  : >"$dir/container-samples/4"

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply when live work exists only after the first volume sample'
  assert_no_grep "$volume" "$dir/volume.rm" \
    'removed a volume mounted by live work after the first sample'
  pass 'the after-sample observation contributes to protected mounts'
}

test_hex_shaped_named_volume_is_kept() {
  local dir volume
  dir=$(fm_hk_case hex-named-volume)
  volume=$(printf 'f%.0s' {1..64})
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s\n' "$volume" >"$dir/volume-samples/2"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''

  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with an unlabeled hex-shaped named volume'
  assert_no_grep "$volume" "$dir/volume.rm" 'removed a named volume based on its name shape'
  pass 'a hex-shaped named volume without anonymous metadata is kept'
}

test_dry_run_models_post_orphan_volume_pass() {
  local dir volume
  dir=$(fm_hk_case dry-post-orphan-volume)
  volume=$(printf '9%.0s' {1..64})
  mkdir -p "$dir/home/data/gone-beta"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  fm_hk_container "$dir" fm-gone-beta-db running '' '' '' ''
  printf 'fm-gone-beta-db|%s\n' "$volume" >"$dir/container-mounts"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"

  fm_hk_run "$dir" --no-worktrees
  expect_code 0 "$?" 'dry run with an orphan-mounted anonymous volume'
  assert_grep 'second volume pass after orphan removal' "$dir/out" \
    'the dry run omitted the distinct second volume pass'
  assert_grep "$volume" "$dir/out" 'the dry run omitted the orphan-mounted volume'
  assert_grep 'upper bound subject to the same apply-time stability check' "$dir/out" \
    'the dry run presented the second-pass model as certain'
  pass 'the dry run models the post-orphan volume pass'
}

test_dry_run_deletes_nothing() {
  local dir volume
  dir=$(fm_hk_case dry-run)
  volume=$(printf 'd%.0s' {1..64})
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s\n' "$volume" >"$dir/volume-samples/2"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"
  mkdir -p "$dir/home/data/gone-beta"
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  fm_hk_container "$dir" fm-gone-beta-db running '' '' '' ''
  fm_hk_container "$dir" junk-cache exited '' '' '' ''

  fm_hk_run "$dir" --no-worktrees
  expect_code 0 "$?" 'default dry run'
  if [ -s "$dir/docker.rm" ]; then
    fail 'the default run removed containers'
  fi
  if grep -q 'prune' "$dir/docker.log"; then
    fail 'the default run pruned'
  fi
  assert_grep 'DRY RUN' "$dir/out" 'the run did not announce itself as a dry run'
  assert_grep 'reclaim fm-gone-beta-db' "$dir/out" 'the dry run did not name the orphan it would reclaim'
  assert_grep 'reclaim junk-cache' "$dir/out" 'the dry run did not name the stopped container it would reclaim'
  assert_grep 'would reclaim 1 stable anonymous volumes' "$dir/out" \
    'the dry run did not report the stable two-sample volume set'
  pass 'the default run reports what it would reclaim and deletes nothing'
}

test_dry_run_models_post_stopped_volume_pass() {
  local dir volume
  dir=$(fm_hk_case dry-post-stopped-volume)
  volume=$(printf '8%.0s' {1..64})
  fm_hk_container "$dir" wffui-pg running '' '' '127.0.0.1:55931->5432/tcp' ''
  fm_hk_container "$dir" junk-cache exited '' '' '' ''
  printf 'junk-cache|%s\n' "$volume" >"$dir/container-mounts"
  printf '%s|com.docker.volume.anonymous|\n' "$volume" >"$dir/volume-metadata"

  fm_hk_run "$dir" --no-worktrees
  expect_code 0 "$?" 'dry run with a stopped-container anonymous volume'
  assert_grep 'first volume pass after stopped containers' "$dir/out" \
    'the dry run omitted the ordered first volume pass'
  assert_grep "$volume" "$dir/out" \
    'the dry run omitted the volume released by the stopped container'

  printf '0\n' >"$dir/volume-sample-count"
  printf '%s\n' "$volume" >"$dir/volume-samples/1"
  printf '%s\n' "$volume" >"$dir/volume-samples/2"
  fm_hk_run "$dir" --apply --no-worktrees
  expect_code 0 "$?" 'apply with the modelled post-stopped volume'
  assert_grep "$volume" "$dir/volume.rm" \
    'the apply first-pass sample diverged from the dry-run model'
  pass 'dry run and apply share the post-stopped volume sequence'
}

test_unattributable_fleet_yields_empty_kill_list
test_degraded_id_listing_still_reclaims_nothing
test_refuses_a_listing_it_cannot_parse
test_orphan_removed_while_live_task_and_stack_are_kept
test_orphan_that_becomes_live_before_removal_is_kept
test_finished_task_name_with_bound_port_is_kept
test_refuses_when_nothing_running_would_be_kept
test_refuses_when_a_name_lands_on_both_lists
test_configured_keep_and_stack_project_protect_stopped_members
test_worktree_phase_never_overrides_the_uncommitted_refusal
test_live_task_worktree_is_refused_before_pruning
test_skipped_live_worktree_does_not_refuse_apply
test_late_live_worktree_loss_is_reported
test_stable_anonymous_volume_is_reclaimed
test_transient_dangling_volume_is_kept
test_nonrunning_protected_container_aborts_volume_phase
test_live_mount_seen_before_first_sample_stays_protected
test_live_mount_seen_after_first_sample_stays_protected
test_hex_shaped_named_volume_is_kept
test_dry_run_models_post_orphan_volume_pass
test_dry_run_deletes_nothing
test_dry_run_models_post_stopped_volume_pass
