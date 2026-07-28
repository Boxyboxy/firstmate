#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | [##########] 100% | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | [..........] 0% | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | [##########] 100% | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | [##########] 100% | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | [#######...] 67% | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | [..........] 0% | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | [##########] 100% | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | - | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | - | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | - | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# --- progress ladder + bar (bin/fm-progress.jq) ------------------------------
# The module is the single owner of both derivation and rendering, so these
# exercise it directly and the snapshot/view tests below only prove the wiring.

PROGRESS_MODULE="$ROOT/bin/fm-progress.jq"
PROGRESS_LIB=$(dirname "$PROGRESS_MODULE")

# progress_of <kind> <mode> <task-overlay-json> -> progress object
progress_of() {
  jq -L "$PROGRESS_LIB" -n --argjson overlay "$3" --arg kind "$1" --arg mode "$2" '
    include "fm-progress";
    ({kind:$kind, mode:$mode,
      paths:{status_log:{present:false}, report:{present:false}},
      current_state:{state:"unknown", source:"none"},
      pr:{url:null},
      hints:{blocked_event:false, pending_decision:false}} * $overlay)
    | fm_progress_of_task(.)'
}

# progress_field <kind> <mode> <overlay> <jq-path>
progress_field() {
  progress_of "$1" "$2" "$3" | jq -r "$4"
}

test_progress_ladder_selection() {
  local row kind mode want got
  [ -f "$PROGRESS_MODULE" ] \
    || fail "the single progress owner bin/fm-progress.jq is missing"
  # kind + mode -> ladder|total. Empty mode must fall back to no-mistakes,
  # which is fm-brief.sh's default delivery mode.
  for row in \
    'ship|no-mistakes|ship-no-mistakes|6' \
    'ship||ship-no-mistakes|6' \
    'ship|not-a-real-mode|ship-no-mistakes|6' \
    'ship|direct-PR|ship-direct-pr|4' \
    'ship|local-only|ship-local-only|4' \
    'scout|scout|scout|3' \
    'scout|no-mistakes|scout|3' \
    'secondmate|secondmate|none|0'
  do
    IFS='|' read -r kind mode want got <<EOF
$row
EOF
    local actual
    actual=$(progress_field "$kind" "$mode" '{}' '"\(.ladder)|\(.total)"')
    [ "$actual" = "$want|$got" ] \
      || fail "kind=$kind mode=$mode should pick $want|$got, got $actual"
  done
  pass "progress ladder is selected from kind and mode, empty mode defaulting to no-mistakes"
}

test_progress_stage_derivation_per_ladder() {
  local row mode overlay want actual
  # mode|task-overlay|expected "stage/reached"
  for row in \
    'no-mistakes|{}|dispatched/1' \
    'no-mistakes|{"paths":{"status_log":{"present":true}}}|working/2' \
    'no-mistakes|{"current_state":{"state":"working","source":"run-step"}}|working/2' \
    'no-mistakes|{"pr":{"url":"https://x/pull/1"}}|pr-open/4' \
    'no-mistakes|{"pr":{"url":"https://x/pull/1"},"hints":{"done_events":["done: PR https://x/pull/1 checks green"]}}|checks-green/5' \
    'direct-PR|{}|dispatched/1' \
    'direct-PR|{"current_state":{"state":"working","source":"pane"}}|working/2' \
    'direct-PR|{"pr":{"url":"https://x/pull/1"}}|pr-open/3' \
    'local-only|{}|dispatched/1' \
    'local-only|{"paths":{"status_log":{"present":true}}}|working/2' \
    'local-only|{"hints":{"done_events":["done: ready in branch fm/x"]}}|ready/3'
  do
    IFS='|' read -r mode overlay want <<EOF
$row
EOF
    actual=$(progress_field ship "$mode" "$overlay" '"\(.stage)/\(.reached)"')
    [ "$actual" = "$want" ] \
      || fail "ship mode=$mode overlay=$overlay should reach $want, got $actual"
  done
  # Scout tops out at its report, which is its deliverable.
  actual=$(progress_field scout scout '{}' '"\(.stage)/\(.reached)"')
  [ "$actual" = "dispatched/1" ] || fail "fresh scout should be dispatched/1, got $actual"
  actual=$(progress_field scout scout '{"paths":{"report":{"present":true},"status_log":{"present":true}}}' \
    '"\(.stage)/\(.reached)/\(.fraction)"')
  [ "$actual" = "report/3/1" ] || fail "scout with a report should be report/3/1, got $actual"
  pass "progress stage derivation follows each ladder's milestone evidence"
}

# `merged` is deliberately unreachable: a merged ship task is torn down and its
# metadata is gone, so a live ship task must top out one stage short.
test_progress_merged_stage_is_never_reached_live() {
  local mode actual
  for mode in no-mistakes direct-PR local-only; do
    actual=$(progress_field ship "$mode" \
      '{"paths":{"status_log":{"present":true},"report":{"present":true}},"pr":{"url":"https://x/pull/1"},"hints":{"done_events":["done: PR https://x/pull/1 checks green","done: ready in branch fm/x"]}}' \
      '"\(.stage)/\(.reached)/\(.total)"')
    case "$actual" in
      merged/*) fail "ship mode=$mode must never reach merged from a live task, got $actual" ;;
    esac
    printf '%s' "$actual" | grep -Eq '^(checks-green|pr-open|ready)/[0-9]+/[0-9]+$' \
      || fail "ship mode=$mode should top out one stage short, got $actual"
  done
  pass "the merged stage is never reachable from a live task"
}

# The monotone high-water rule: a transient state must never pull the bar
# backwards. A task that recorded a PR and then hit a decision hold stays at the
# PR stage and raises a flag instead of dropping back to working.
test_progress_is_monotone_high_water() {
  local actual
  actual=$(progress_field ship no-mistakes \
    '{"pr":{"url":"https://x/pull/1"},"current_state":{"state":"parked","source":"status-log"},"hints":{"pending_decision":true,"blocked_event":false}}' \
    '"\(.stage)/\(.reached)/\(.flag)"')
  [ "$actual" = "pr-open/4/decision" ] \
    || fail "a PR plus a decision hold must stay at pr-open and flag decision, got $actual"
  # The same is true for a failure after a PR: the bar holds, the flag changes.
  actual=$(progress_field ship no-mistakes \
    '{"pr":{"url":"https://x/pull/1"},"current_state":{"state":"failed","source":"pane"}}' \
    '"\(.stage)/\(.reached)/\(.flag)"')
  [ "$actual" = "pr-open/4/failed" ] \
    || fail "a PR plus a failure must stay at pr-open and flag failed, got $actual"
  pass "progress is monotone high-water; exceptional states raise a flag, never a lower fill"
}

# Terminal milestones must key off the append-only status log, never off
# current_state. current_state is a LIVE read that decays: fm-crew-state.sh falls
# back run-step -> pane -> status-log once a run stops being attributable. A
# milestone keyed off it would drop checks-green from 5/6 to 4/6 between two
# snapshots of unchanged work, which is exactly the bar going backwards.
test_progress_terminal_milestones_survive_current_state_decay() {
  local src actual
  for src in run-step pane status-log none; do
    actual=$(progress_field ship no-mistakes \
      "{\"pr\":{\"url\":\"https://x/pull/1\"},\"current_state\":{\"state\":\"done\",\"source\":\"$src\"},\"hints\":{\"done_events\":[\"done: PR https://x/pull/1 checks green\"]}}" \
      '"\(.stage)/\(.reached)"')
    [ "$actual" = "checks-green/5" ] \
      || fail "checks-green must hold as current_state decays to $src, got $actual"
    actual=$(progress_field ship local-only \
      "{\"current_state\":{\"state\":\"unknown\",\"source\":\"$src\"},\"hints\":{\"done_events\":[\"done: ready in branch fm/x\"]}}" \
      '"\(.stage)/\(.reached)"')
    [ "$actual" = "ready/3" ] \
      || fail "ready must hold as current_state decays to $src, got $actual"
  done
  # No rung may be held up by current_state at all. `validating` once keyed off
  # source == "run-step" and dropped 3/6 back to 2/6 the moment attribution was
  # lost, so it now shares pr-open's durable evidence: the fill must depend only
  # on the recorded PR, identically across every source value.
  for src in run-step pane status-log none; do
    actual=$(progress_field ship no-mistakes \
      "{\"paths\":{\"status_log\":{\"present\":true}},\"current_state\":{\"state\":\"working\",\"source\":\"$src\"}}" \
      '"\(.stage)/\(.reached)"')
    [ "$actual" = "working/2" ] \
      || fail "a PR-less task must stay at working as current_state reads $src, got $actual"
    actual=$(progress_field ship no-mistakes \
      "{\"paths\":{\"status_log\":{\"present\":true}},\"current_state\":{\"state\":\"working\",\"source\":\"$src\"},\"pr\":{\"url\":\"https://x/pull/1\"}}" \
      '"\(.stage)/\(.reached)"')
    [ "$actual" = "pr-open/4" ] \
      || fail "a task with a PR must hold pr-open as current_state reads $src, got $actual"
  done
  # A raw last event of any verb must never satisfy a terminal milestone: only
  # the snapshot's verb-filtered done_events list can.
  actual=$(progress_field ship no-mistakes \
    '{"pr":{"url":"https://x/pull/1"},"hints":{"last_event_text":"working: rebased onto merged #76, checks green upstream"}}' \
    '"\(.stage)/\(.reached)"')
  [ "$actual" = "pr-open/4" ] \
    || fail "a non-done last event must not prove checks green, got $actual"
  actual=$(progress_field ship local-only \
    '{"hints":{"last_event_text":"working: ready in branch soon"}}' \
    '"\(.stage)/\(.reached)"')
  [ "$actual" = "dispatched/1" ] \
    || fail "a non-done last event must not prove ready, got $actual"
  # A later unrelated appended line must not retract a recorded milestone either.
  actual=$(progress_field ship no-mistakes \
    '{"pr":{"url":"https://x/pull/1"},"current_state":{"state":"working","source":"pane"},"hints":{"done_events":["done: PR https://x/pull/1 checks green"],"last_event_text":"working: answering a follow-up"}}' \
    '"\(.stage)/\(.reached)"')
  [ "$actual" = "checks-green/5" ] \
    || fail "a later status line must not retract checks-green, got $actual"
  # direct-PR reports only `done: PR <url>`, which is never proof of green checks.
  actual=$(progress_field ship no-mistakes \
    '{"pr":{"url":"https://x/pull/1"},"hints":{"done_events":["done: PR https://x/pull/1"]}}' \
    '"\(.stage)/\(.reached)"')
  [ "$actual" = "pr-open/4" ] \
    || fail "a bare done: PR line must not prove checks green, got $actual"
  pass "terminal milestones key off the append-only log and survive current_state decay"
}

test_progress_flag_precedence() {
  local row overlay want actual
  # overlay|expected flag. Precedence: failed, blocked, decision,
  # awaiting-merge, paused, then null.
  for row in \
    '{"current_state":{"state":"failed","source":"pane"},"hints":{"blocked_event":true,"pending_decision":true}}|failed' \
    '{"hints":{"blocked_event":true,"pending_decision":true}}|blocked' \
    '{"hints":{"blocked_event":false,"pending_decision":true}}|decision' \
    '{"current_state":{"state":"parked","source":"run-step"}}|decision' \
    '{"current_state":{"state":"paused","source":"pane"}}|paused' \
    '{"current_state":{"state":"working","source":"pane"}}|null'
  do
    IFS='|' read -r overlay want <<EOF
$row
EOF
    actual=$(progress_field ship no-mistakes "$overlay" '.flag')
    [ "$actual" = "$want" ] \
      || fail "overlay=$overlay should flag $want, got $actual"
  done
  pass "progress flag precedence is failed, blocked, decision, awaiting-merge, paused, null"
}

# Both decision arms are load-bearing and neither subsumes the other. A
# no-mistakes run parked at an awaiting_approval or fix_review gate never
# appends a needs-decision: status line, so the event-fold arm alone misses it.
test_progress_decision_flag_has_two_independent_arms() {
  local actual
  actual=$(progress_field ship no-mistakes \
    '{"current_state":{"state":"parked","source":"run-step"},"hints":{"pending_decision":false,"blocked_event":false}}' \
    '.flag')
  [ "$actual" = decision ] \
    || fail "a run parked at a gate with no needs-decision event must flag decision, got $actual"
  actual=$(progress_field ship no-mistakes \
    '{"current_state":{"state":"working","source":"pane"},"hints":{"pending_decision":true,"blocked_event":false}}' \
    '.flag')
  [ "$actual" = decision ] \
    || fail "a folded needs-decision event must flag decision without a parked state, got $actual"
  # The parked arm must not outrank a real failure or blocker above it.
  actual=$(progress_field ship no-mistakes \
    '{"current_state":{"state":"parked","source":"run-step"},"hints":{"blocked_event":true,"pending_decision":false}}' \
    '.flag')
  [ "$actual" = blocked ] || fail "blocked must still outrank a parked decision, got $actual"
  # A parked run still holds its high-water stage rather than dropping back.
  actual=$(progress_field ship no-mistakes \
    '{"pr":{"url":"https://x/pull/1"},"current_state":{"state":"parked","source":"run-step"}}' \
    '"\(.stage)/\(.flag)"')
  [ "$actual" = "pr-open/decision" ] \
    || fail "a parked run must hold its stage and flag decision, got $actual"
  pass "the decision flag fires from a folded event or a parked gate, independently"
}

# awaiting-merge is the most important marker on the board: it means the work is
# finished and sitting on the captain. Without it, "done, waiting on you" renders
# as a bare bar indistinguishable from "still grinding".
test_progress_awaiting_merge_per_ship_ladder() {
  local row mode overlay want actual
  for row in \
    'no-mistakes|{"pr":{"url":"https://x/pull/1"},"hints":{"done_events":["done: PR https://x/pull/1 checks green"]}}|checks-green' \
    'direct-PR|{"pr":{"url":"https://x/pull/1"},"hints":{"done_events":["done: PR https://x/pull/1"]}}|pr-open' \
    'local-only|{"hints":{"done_events":["done: ready in branch fm/x"]}}|ready'
  do
    IFS='|' read -r mode overlay want <<EOF
$row
EOF
    actual=$(progress_field ship "$mode" "$overlay" '"\(.stage)/\(.flag)"')
    [ "$actual" = "$want/awaiting-merge" ] \
      || fail "ship mode=$mode at its top stage should flag $want/awaiting-merge, got $actual"
  done
  # It outranks paused but yields to a still-open decision.
  actual=$(progress_field ship local-only \
    '{"hints":{"done_events":["done: ready in branch fm/x"],"pending_decision":true,"blocked_event":false}}' '.flag')
  [ "$actual" = decision ] || fail "an open decision must outrank awaiting-merge, got $actual"
  # A scout's report is its deliverable, not something awaiting a merge.
  actual=$(progress_field scout scout \
    '{"paths":{"report":{"present":true},"status_log":{"present":true}},"hints":{"done_events":["done: report ready"]}}' '.flag')
  [ "$actual" = null ] || fail "a completed scout must not be flagged awaiting-merge, got $actual"
  pass "awaiting-merge fires at the top reachable stage of every ship ladder only"
}

test_progress_secondmate_has_no_ladder() {
  local out
  out=$(jq -L "$PROGRESS_LIB" -rn '
    include "fm-progress";
    ({kind:"secondmate", mode:"secondmate",
      paths:{status_log:{present:true}, report:{present:false}},
      current_state:{state:"working", source:"pane"},
      pr:{url:null},
      hints:{blocked_event:false, pending_decision:false}}
     | fm_progress_of_task(.)) as $p
    | "\($p.ladder)/\($p.total)/\($p.stage)/\($p.fraction)/\(fm_progress_bar($p; 10))"')
  [ "$out" = "none/0/null/null/-" ] \
    || fail "a persistent secondmate has no finish line and must render no bar, got $out"
  pass "a persistent secondmate gets ladder none and renders no bar"
}

test_progress_of_backlog_records() {
  local row state want actual
  for row in \
    'queued|backlog/2/null/0/queued' \
    'in_flight|backlog/2/under-way/1/under way' \
    'done|backlog/2/landed/2/landed' \
    'nonsense|backlog/2/null/0/unknown backlog state'
  do
    IFS='|' read -r state want <<EOF
$row
EOF
    actual=$(jq -L "$PROGRESS_LIB" -rn --arg state "$state" '
      include "fm-progress";
      fm_progress_of_backlog({state:$state}) as $p
      | "\($p.ladder)/\($p.total)/\($p.stage)/\($p.reached)/\($p.evidence)"')
    [ "$actual" = "$want" ] \
      || fail "backlog state=$state should derive $want, got $actual"
  done
  # Backlog records carry no worker telemetry, so they never carry a flag.
  actual=$(jq -L "$PROGRESS_LIB" -rn '
    include "fm-progress"; [fm_progress_of_backlog({state:"in_flight"}).flag] | tostring')
  [ "$actual" = "[null]" ] || fail "backlog records must never carry a flag, got $actual"
  pass "backlog records derive the two-stage under-way/landed ladder"
}

test_progress_bar_formatting() {
  local row p want actual
  # progress-object|expected bar at width 10
  for row in \
    '{"ladder":"backlog","total":2,"reached":0,"fraction":0,"flag":null}|[..........] 0%' \
    '{"ladder":"scout","total":3,"reached":1,"fraction":0.33,"flag":null}|[###.......] 33%' \
    '{"ladder":"ship-no-mistakes","total":6,"reached":3,"fraction":0.5,"flag":null}|[#####.....] 50%' \
    '{"ladder":"ship-no-mistakes","total":6,"reached":3,"fraction":0.5,"flag":"decision"}|[#####.....] 50% !decision' \
    '{"ladder":"ship-no-mistakes","total":6,"reached":5,"fraction":0.83,"flag":"awaiting-merge"}|[########..] 83% !awaiting-merge' \
    '{"ladder":"backlog","total":2,"reached":2,"fraction":1,"flag":null}|[##########] 100%' \
    '{"ladder":"none","total":0,"reached":0,"fraction":null,"flag":null}|-' \
    'null|-'
  do
    IFS='|' read -r p want <<EOF
$row
EOF
    actual=$(jq -L "$PROGRESS_LIB" -rn --argjson p "$p" '
      include "fm-progress"; fm_progress_bar($p; 10)')
    [ "$actual" = "$want" ] || fail "bar for $p should be '$want', got '$actual'"
  done
  # ASCII only: locale- and font-sensitive glyphs must never reach agent-parsed output.
  actual=$(jq -L "$PROGRESS_LIB" -rn '
    include "fm-progress";
    fm_progress_bar({ladder:"scout",total:3,reached:2,fraction:0.67,flag:"blocked"}; 10)')
  printf '%s' "$actual" | LC_ALL=C grep -q '^[][#.[:alnum:][:space:]!%-]*$' \
    || fail "the bar must stay ASCII, got '$actual'"
  pass "the progress bar renders ASCII fills, integer percent, and an optional flag suffix"
}

# End-to-end proof that the snapshot surfaces the append-only done: lines the
# module reads, using real status logs rather than injected hints.
test_snapshot_surfaces_durable_done_events() {
  local home fakebin out
  home=$(make_home done-events)
  mkdir -p "$home/projects/green" "$home/projects/ready" "$home/projects/opened"
  fm_write_meta "$home/state/green-ship.meta" \
    "window=firstmate:fm-green-ship" "worktree=$home/projects/green" "project=alpha" \
    "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/kunchenguid/firstmate/pull/21"
  # A later working line after the milestone must not retract it. The keyed
  # `done [key=<slug>]:` form must be collected too: the verb is read with
  # fm-classify-lib.sh's status_line_verb, which strips the key token, so a
  # second parser that matched a bare `done:` prefix would silently drop it.
  printf 'working: implementing\ndone: PR https://github.com/kunchenguid/firstmate/pull/21 checks green\nworking: answering a follow-up\ndone [key=followup]: PR https://github.com/kunchenguid/firstmate/pull/21 still checks green\n' \
    > "$home/state/green-ship.status"
  fm_write_meta "$home/state/ready-ship.meta" \
    "window=firstmate:fm-ready-ship" "worktree=$home/projects/ready" "project=alpha" \
    "harness=codex" "kind=ship" "mode=local-only"
  printf 'done: ready in branch fm/ready-ship\n' > "$home/state/ready-ship.status"
  fm_write_meta "$home/state/opened-ship.meta" \
    "window=firstmate:fm-opened-ship" "worktree=$home/projects/opened" "project=alpha" \
    "harness=codex" "kind=ship" "mode=direct-PR" \
    "pr=https://github.com/kunchenguid/firstmate/pull/22"
  printf 'done: PR https://github.com/kunchenguid/firstmate/pull/22\n' \
    > "$home/state/opened-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    (.tasks[] | select(.id == "green-ship")
      | (.hints.done_events | length) == 2
        and (.hints.done_events | any(startswith("done [key=followup]:")))
        and (.hints.done_events | all(startswith("working:") | not))
        and .progress.stage == "checks-green"
        and .progress.reached == 5
        and .progress.flag == "awaiting-merge")
    and (.tasks[] | select(.id == "ready-ship")
      | .progress.stage == "ready" and .progress.reached == 3
        and .progress.flag == "awaiting-merge")
    and (.tasks[] | select(.id == "opened-ship")
      | .progress.stage == "pr-open" and .progress.reached == 3
        and .progress.flag == "awaiting-merge")
  ' >/dev/null || fail "durable done: evidence did not reach progress derivation: $out"
  pass "the snapshot surfaces durable done: lines and they drive terminal milestones"
}

test_snapshot_and_view_carry_progress() {
  local home fakebin out view
  home=$(make_home progress-wiring)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  # The field is purely additive; the schema string must not move.
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null \
    || fail "adding progress must not change the snapshot schema string"
  printf '%s' "$out" | jq -e '
    (.tasks | length) > 0
      and all(.tasks[]; .progress != null and (.progress | has("ladder") and has("stages")
        and has("stage") and has("reached") and has("total") and has("fraction")
        and has("flag") and has("evidence")))
  ' >/dev/null || fail "every task must carry a full progress object: $out"
  printf '%s' "$out" | jq -e '
    (.backlog.records | length) > 0
      and all(.backlog.records[]; .progress.ladder == "backlog" and .progress.total == 2)
  ' >/dev/null || fail "every backlog record must carry the backlog progress ladder: $out"
  # ship-task has a recorded PR and a live working pane, so it sits at pr-open
  # with no flag: its status-log decision was already cleared by the lifecycle
  # reconciliation this snapshot owns.
  printf '%s' "$out" | jq -e '
    (.tasks[] | select(.id == "ship-task") | .progress.stage) == "pr-open"
      and (.tasks[] | select(.id == "ship-task") | .progress.reached) == 4
      and (.tasks[] | select(.id == "ship-task") | .progress.flag) == null
      and (.tasks[] | select(.id == "scout-task") | .progress.ladder) == "scout"
      and (.tasks[] | select(.id == "scout-task") | .progress.stage) == "report"
      and (.tasks[] | select(.id == "secondmate-task") | .progress.ladder) == "none"
      and (.backlog.records[] | select(.id == "done-task") | .progress.stage) == "landed"
  ' >/dev/null || fail "snapshot progress derivation wrong on the fixture: $out"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ID | Current | Progress | Kind |" \
    "under way table should carry a Progress column"
  assert_contains "$view" "| ID | Title | Progress | Repo |" \
    "queued and done tables should carry a Progress column"
  assert_contains "$view" "| ship-task | working / pane | [#######...] 67% |" \
    "view should render the ship task bar at its recorded-PR stage"
  assert_contains "$view" "| secondmate-task | working / status-log | - |" \
    "view should render no bar for a persistent secondmate"
  assert_contains "$view" "| done-task | Done Task | [##########] 100% |" \
    "view should render a landed backlog row at 100%"
  assert_contains "$view" "| queued-task | Queued Task | [..........] 0% |" \
    "view should render a queued backlog row at 0%"
  pass "snapshot emits progress on tasks and backlog records, and the view renders it"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_progress_ladder_selection
test_progress_stage_derivation_per_ladder
test_progress_merged_stage_is_never_reached_live
test_progress_terminal_milestones_survive_current_state_decay
test_progress_is_monotone_high_water
test_progress_flag_precedence
test_progress_decision_flag_has_two_independent_arms
test_progress_awaiting_merge_per_ship_ladder
test_progress_secondmate_has_no_ladder
test_progress_of_backlog_records
test_progress_bar_formatting
test_snapshot_surfaces_durable_done_events
test_snapshot_and_view_carry_progress
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
