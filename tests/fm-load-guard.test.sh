#!/usr/bin/env bash
# Behavior tests for bin/fm-load-guard.sh, the standing memory and CPU check,
# and for the two places that consume it: bin/fm-bootstrap.sh arms it in every
# home, and bin/fm-spawn.sh reads it before every launch.
#
# Measurement is driven through the script's own seams so no case depends on
# this host's real load: FM_LOAD_GUARD_PLATFORM picks the parser, a fake /proc
# directory feeds the Linux parser, and PATH fakes for memory_pressure and
# iostat feed the macOS parser. A no-op `sleep` on PATH keeps the Linux CPU
# sample pair instant.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# tests/lib.sh pins the guard off for every other suite; this one exercises it.
unset FM_LOAD_GUARD

GUARD="$ROOT/bin/fm-load-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-load-guard)

# make_home <name>: a scratch home with a fake /proc, macOS tool fakes, and a
# no-op sleep. Defaults to a healthy Linux reading.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/proc" "$home/fakebin" "$home/darwin"
  cat > "$home/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$home/fakebin/memory_pressure" <<SH
#!/usr/bin/env bash
[ -f '$home/darwin/memory_pressure.out' ] || exit 1
cat '$home/darwin/memory_pressure.out'
SH
  cat > "$home/fakebin/iostat" <<SH
#!/usr/bin/env bash
[ -f '$home/darwin/iostat.out' ] || exit 1
cat '$home/darwin/iostat.out'
SH
  chmod +x "$home/fakebin"/*
  set_linux "$home" 60 80
  printf '%s\n' "$home"
}

# set_linux <home> <memory-available-pct> <cpu-idle-pct>: a /proc fixture whose
# meminfo and pair of /proc/stat samples yield exactly those percentages. The
# idle share counts idle plus iowait over the 1000-jiffy interval.
set_linux() {
  local home=$1 mem=$2 idle=$3 busy
  busy=$((1000 - idle * 10))
  printf 'MemTotal:       1000000 kB\nMemFree:          10000 kB\nMemAvailable:   %d kB\n' \
    "$((mem * 10000))" > "$home/proc/meminfo"
  printf 'cpu  600 0 200 150 50 0 0 0 0 0\ncpu0 300 0 100 75 25 0 0 0 0 0\n' > "$home/proc/stat"
  printf 'cpu  %d 0 200 %d 50 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0 0 0\n' \
    "$((600 + busy))" "$((150 + idle * 10))" > "$home/proc/stat.later"
}

# guard <home> <action> [env...]: run the guard against <home>'s fixtures.
guard() {
  local home=$1 action=$2
  shift 2
  env FM_HOME="$home" FM_LOAD_GUARD_PLATFORM="${PLATFORM:-linux}" \
    FM_LOAD_GUARD_PROC_DIR="$home/proc" FM_LOAD_GUARD_PROC_STAT_LATER="$home/proc/stat.later" \
    PATH="$home/fakebin:$PATH" "$@" "$GUARD" "$action"
}

field() {  # <status-output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

test_linux_parser_reads_meminfo_and_stat_deltas() {
  local home out
  home=$(make_home linux-parser)
  set_linux "$home" 20 7
  out=$(guard "$home" status)
  assert_equals 20 "$(field "$out" memory_free_pct)" "MemAvailable/MemTotal was not read as 20%"
  assert_equals 7 "$(field "$out" cpu_idle_pct)" "the idle+iowait share of the two samples was not 7%"
  assert_equals alert "$(field "$out" verdict)" "20% free and 7% idle should alert without refusing"
  pass "linux: memory comes from MemAvailable and CPU idle from the delta of two /proc/stat samples"
}

test_darwin_parser_reads_memory_pressure_and_measured_iostat_row() {
  local home out
  home=$(make_home darwin-parser)
  printf '%s\n' 'The system has 17179869184 (4194304 pages with a page size of 4096).' \
    'System-wide memory free percentage: 12%' > "$home/darwin/memory_pressure.out"
  # Two disk blocks precede the cpu block, and the first row is the since-boot
  # average (55% idle); only the second, measured row (5% idle) counts.
  cat > "$home/darwin/iostat.out" <<'EOF'
              disk0               disk4       cpu    load average
    KB/t  tps  MB/s     KB/t  tps  MB/s  us sy id   1m   5m   15m
   24.21 1397 33.02   839.11    0  0.01  28 16 55  10.48 8.56 9.01
   17.90 2241 39.17     0.00    0  0.00  70 25  5  10.48 8.56 9.01
EOF
  out=$(PLATFORM=darwin guard "$home" status)
  assert_equals 12 "$(field "$out" memory_free_pct)" "memory_pressure free percentage was not parsed"
  assert_equals 5 "$(field "$out" cpu_idle_pct)" "the measured iostat row's id column was not used"
  assert_equals refuse "$(field "$out" verdict)" "12% free is below the default 15% spawn floor"
  pass "darwin: memory_pressure free percentage and the measured iostat idle column are read by header"
}

test_unmeasurable_readings_never_alarm() {
  local home out
  home=$(make_home unmeasurable)
  out=$(PLATFORM=plan9 guard "$home" check)
  assert_equals '' "$out" "an unknown platform printed a wake line"
  out=$(PLATFORM=plan9 guard "$home" status)
  assert_equals unknown "$(field "$out" verdict)" "an unknown platform did not report an unknown verdict"
  # macOS with both probes failing or printing garbage.
  printf 'nothing useful\n' > "$home/darwin/iostat.out"
  out=$(PLATFORM=darwin guard "$home" check)
  assert_equals '' "$out" "failed macOS probes printed a wake line"
  # Linux with no meminfo and an unchanged stat pair (no elapsed jiffies).
  rm -f "$home/proc/meminfo"
  cp "$home/proc/stat" "$home/proc/stat.later"
  out=$(guard "$home" check)
  assert_equals '' "$out" "unreadable /proc printed a wake line"
  assert_absent "$home/state/.load-guard" "an unmeasurable poll recorded an episode"
  pass "an unknown platform, failed probes, or unreadable /proc print nothing and record nothing"
}

test_healthy_reading_is_silent() {
  local home out
  home=$(make_home healthy)
  out=$(guard "$home" check)
  assert_equals '' "$out" "a healthy reading printed a wake line"
  assert_absent "$home/state/.load-guard" "a healthy reading recorded an episode"
  pass "a reading under no threshold is silent"
}

test_episode_alerts_once_then_reminds_then_ends() {
  local home out
  home=$(make_home dedupe)
  set_linux "$home" 20 60

  out=$(guard "$home" check FM_LOAD_GUARD_NOW=10000)
  assert_contains "$out" "load-guard: memory 20% free (alert below 25%), CPU 60% idle - high load" "episode start did not alert"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the wake was not exactly one line: $out"

  out=$(guard "$home" check FM_LOAD_GUARD_NOW=10300)
  assert_equals '' "$out" "a sustained episode woke again on the next poll"

  set_linux "$home" 20 4
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=10600)
  assert_contains "$out" "CPU 4% idle (alert below 10%) - load worsened, high since 10m ago" "a newly crossed metric was not news"

  out=$(guard "$home" check FM_LOAD_GUARD_NOW=12000)
  assert_equals '' "$out" "the reminder fired before remind_secs elapsed since the last alert"
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=12400)
  assert_contains "$out" "still high after 40m" "no reminder once remind_secs elapsed"

  set_linux "$home" 60 60
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=12700)
  assert_equals '' "$out" "recovery printed a wake line"
  assert_absent "$home/state/.load-guard" "recovery did not end the episode"

  set_linux "$home" 20 60
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=13000)
  assert_contains "$out" "- high load" "a returning condition was not reported as a new episode"
  pass "a sustained condition alerts at its start, when it worsens, and once per remind_secs, and ends on recovery"
}

test_unmeasured_metric_keeps_the_episode() {
  local home out
  home=$(make_home carried)
  set_linux "$home" 60 4
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=20000)
  assert_contains "$out" "CPU 4% idle" "the CPU episode did not start"
  # One poll cannot sample the CPU: the episode is neither ended nor restarted.
  cp "$home/proc/stat" "$home/proc/stat.later"
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=20300)
  assert_equals '' "$out" "an unmeasured CPU with healthy memory printed a wake line"
  assert_grep 'crossed=cpu' "$home/state/.load-guard" "an unmeasured CPU ended the episode"
  set_linux "$home" 60 4
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=20600)
  assert_equals '' "$out" "a CPU sample returning mid-episode re-alerted as a new episode"
  pass "a metric that cannot be measured on one poll keeps its recorded episode state"
}

test_config_thresholds_off_and_malformed() {
  local home out
  home=$(make_home config)
  set_linux "$home" 40 30
  printf '%s\n' '# tighter on this host' 'memory_free_alert_pct=50' 'cpu_idle_alert_pct=35' \
    'memory_free_spawn_floor_pct=45' 'remind_secs=0' > "$home/config/load-guard"
  out=$(guard "$home" status)
  assert_equals refuse "$(field "$out" verdict)" "configured thresholds were not applied"
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=30000)
  assert_contains "$out" "memory 40% free (alert below 50%), CPU 30% idle (alert below 35%)" "configured alert thresholds were not used"
  assert_contains "$out" "new spawns refused below 45% free" "the configured spawn floor was not named"
  out=$(guard "$home" check FM_LOAD_GUARD_NOW=99999)
  assert_equals '' "$out" "remind_secs=0 still sent a reminder"

  printf 'off\n' > "$home/config/load-guard"
  out=$(guard "$home" check)
  assert_equals '' "$out" "an off guard printed a wake line"
  assert_absent "$home/state/.load-guard" "turning the guard off kept a stale episode"
  assert_equals off "$(field "$(guard "$home" status)" verdict)" "status did not report off"
  printf '' > "$home/config/load-guard"
  assert_equals off "$(field "$(guard "$home" status FM_LOAD_GUARD=off)" verdict)" "FM_LOAD_GUARD=off was not honored"

  printf 'memory_free_alert_pct=250\n' > "$home/config/load-guard"
  set_linux "$home" 60 60
  out=$(guard "$home" check)
  assert_contains "$out" "load-guard: config/load-guard: memory_free_alert_pct must be 1..99 (using defaults)" "a malformed file was not reported"
  out=$(guard "$home" check)
  assert_equals '' "$out" "the same malformed file was reported on every poll"
  set_linux "$home" 20 60
  out=$(guard "$home" check)
  assert_contains "$out" "memory 20% free (alert below 25%)" "defaults were not used while the file was malformed"
  printf 'memory_free_spawn_floor_pct=30\n' > "$home/config/load-guard"
  out=$(guard "$home" status)
  assert_contains "$(field "$out" config_error)" "is above memory_free_alert_pct (25)" "a floor above the alert threshold was accepted"
  pass "config/load-guard sets thresholds, 'off' silences everything, and a malformed file is reported once"
}

test_arm_is_idempotent_executes_and_follows_off() {
  local home out first second
  home=$(make_home arm)
  printf '#!/bin/bash\necho hand-written\n' > "$home/state/load-guard.check.sh"
  chmod 700 "$home/state/load-guard.check.sh"
  out=$(guard "$home" arm) || fail "arm failed: $out"
  assert_contains "$out" "armed: state/load-guard.check.sh" "arm did not report"
  assert_no_grep 'hand-written' "$home/state/load-guard.check.sh" "arm left a hand-written shim in place"
  FM_HOME="$home" bash -c '. "$1/bin/fm-check-lib.sh"; . "$1/bin/fm-pr-lib.sh"; fm_custom_check_registered "$2" load-guard' _ \
    "$ROOT" "$home/state" || fail "the armed shim is not bound to its trust record"
  first=$(ls -li "$home/state/load-guard.check.sh" "$home/state/load-guard.check-trust")
  out=$(guard "$home" arm) || fail "re-arm failed: $out"
  second=$(ls -li "$home/state/load-guard.check.sh" "$home/state/load-guard.check-trust")
  assert_equals "$first" "$second" "re-arming an armed home rewrote its shim or trust record"

  # The shim itself runs this home's check.
  set_linux "$home" 10 60
  out=$(FM_LOAD_GUARD_PLATFORM=linux FM_LOAD_GUARD_PROC_DIR="$home/proc" \
    FM_LOAD_GUARD_PROC_STAT_LATER="$home/proc/stat.later" PATH="$home/fakebin:$PATH" \
    "$home/state/load-guard.check.sh")
  assert_contains "$out" "load-guard: memory 10% free" "the armed shim did not run this home's check"

  printf 'off\n' > "$home/config/load-guard"
  out=$(guard "$home" arm) || fail "arm under off failed: $out"
  assert_contains "$out" "load guard is off" "arm under off did not say so"
  assert_absent "$home/state/load-guard.check.sh" "arm under off left the shim"
  assert_absent "$home/state/load-guard.check-trust" "arm under off left the trust binding"
  assert_absent "$home/state/.load-guard" "arm under off left the episode record"
  pass "arm replaces a hand-written shim, is a no-op when converged, runs the home's check, and disarms when off"
}

test_bootstrap_arms_every_home() {
  local home out
  home=$(make_home bootstrap)
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_not_contains "$out" "LOAD_GUARD:" "bootstrap reported an arming failure"
  assert_present "$home/state/load-guard.check.sh" "bootstrap did not arm the load guard"
  assert_present "$home/state/load-guard.check-trust" "bootstrap did not bind the load guard"
  printf 'off\n' > "$home/config/load-guard"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_absent "$home/state/load-guard.check.sh" "bootstrap kept the load guard armed after config/load-guard said off"
  pass "bootstrap arms the load guard in a home and disarms it when the home opts out"
}

# --- spawn gate ---------------------------------------------------------------

make_spawn_case() {  # <name> <id> -> case record
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  mkdir -p "$home/proc"
  set_linux "$home" 60 60
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

spawn_with_load() {  # <record> <id> [env...]
  local rec=$1 id=$2 home proj wt fakebin
  shift 2
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  (
    export FM_LOAD_GUARD_PLATFORM=linux FM_LOAD_GUARD_PROC_DIR="$home/proc" \
      FM_LOAD_GUARD_PROC_STAT_LATER="$home/proc/stat.later"
    for kv in "$@"; do export "${kv?}"; done
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off
  )
}

test_spawn_warns_refuses_and_records_override() {
  local rec home out status id
  id=load-warn-z1
  rec=$(make_spawn_case warn "$id")
  home=${rec%%|*}
  set_linux "$home" 20 5
  out=$(spawn_with_load "$rec" "$id")
  status=$?
  expect_code 0 "$status" "a crossed alert threshold above the floor should still spawn: $out"
  assert_contains "$out" "warning: this machine is under load (memory 20% free (alert below 25%), CPU 5% idle (alert below 10%))" "the spawn did not warn"
  assert_no_grep 'load_guard_override=' "$home/state/$id.meta" "a warned spawn recorded an override"

  id=load-refuse-z1
  rec=$(make_spawn_case refuse "$id")
  home=${rec%%|*}
  set_linux "$home" 10 60
  out=$(spawn_with_load "$rec" "$id")
  status=$?
  expect_code 1 "$status" "memory below the spawn floor did not refuse: $out"
  assert_contains "$out" "error: spawn refused - memory is below the load guard's spawn floor of 15% free" "the refusal did not name the floor"
  assert_absent "$home/state/$id.meta" "a refused spawn left a task record"

  out=$(spawn_with_load "$rec" "$id" 'FM_LOAD_GUARD_OVERRIDE=captain approved one more')
  status=$?
  expect_code 0 "$status" "an override reason did not let the spawn through: $out"
  assert_contains "$out" "launching $id anyway under FM_LOAD_GUARD_OVERRIDE: captain approved one more" "the override was not announced"
  assert_grep 'load_guard_override=captain approved one more' "$home/state/$id.meta" "the override reason was not recorded in the task record"

  id=load-unknown-z1
  rec=$(make_spawn_case unknown "$id")
  home=${rec%%|*}
  rm -f "$home/proc/meminfo" "$home/proc/stat"
  out=$(spawn_with_load "$rec" "$id")
  status=$?
  expect_code 0 "$status" "an unmeasurable reading blocked the spawn: $out"
  assert_not_contains "$out" "under load" "an unmeasurable reading produced a load warning"
  assert_not_contains "$out" "spawn floor" "an unmeasurable reading was treated as below the floor"
  pass "spawn warns over an alert threshold, refuses below the memory floor unless overridden with a recorded reason, and never refuses on an unknown reading"
}

test_linux_parser_reads_meminfo_and_stat_deltas
test_darwin_parser_reads_memory_pressure_and_measured_iostat_row
test_unmeasurable_readings_never_alarm
test_healthy_reading_is_silent
test_episode_alerts_once_then_reminds_then_ends
test_unmeasured_metric_keeps_the_episode
test_config_thresholds_off_and_malformed
test_arm_is_idempotent_executes_and_follows_off
test_bootstrap_arms_every_home
test_spawn_warns_refuses_and_records_override
