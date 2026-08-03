#!/usr/bin/env bash
# Behavior tests for the omp (Oh My Pi) harness adapter: detection precedence,
# crewmate/secondmate launch construction, the turn-end SIGNAL extension, model/
# effort flag threading, the meta profile, and the delivery-guard busy token it
# shares with fm-tmux-lib.sh. Task busy STATE is owned by bin/fm-busy-lib.sh's
# semantic contract and is covered by tests/fm-busy-adapter-wiring.test.sh.
#
# Modeled on tests/fm-spawn-dispatch-profile.test.sh (NOT fm-grok-harness): a
# fake tmux captures the literal command sent with `tmux send-keys -l`, so the
# launch assertions pin exactly what firstmate would run without starting a real
# harness. The spawn helpers below are copied from that file so this suite is
# self-contained.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS_BIN="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMUX_LIB="$ROOT/bin/fm-tmux-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

# --- spawn harness (mirrors fm-spawn-dispatch-profile.test.sh) --------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    {
      printf 'brief for %s\n' "$id"
      printf 'Delivery contract: mode=no-mistakes\n'
    } > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 arg
  local -a delivery
  shift 4
  delivery=(--mode no-mistakes --yolo off)
  for arg in "$@"; do
    case "$arg" in
      --secondmate|--scout) delivery=(); break ;;
    esac
  done
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" "${delivery[@]+"${delivery[@]}"}" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

# --- detection (Layer 1 markers + Layer 2 ancestry) -------------------------

# Detection 1 (REQUIRED): omp sets BOTH OMPCODE and CLAUDECODE, so OMPCODE must
# win the Layer-1 order or omp mis-detects as claude.
test_omp_detection_ompcode_beats_claudecode() {
  local out
  out=$(OMPCODE=1 CLAUDECODE=1 "$HARNESS_BIN")
  [ "$out" = omp ] || fail "detect_own must prefer OMPCODE over CLAUDECODE, got '$out'"
  pass "detect_own returns omp when both OMPCODE and CLAUDECODE are set (OMPCODE wins)"
}

# Detection 2 (RECOMMENDED): the OMPCODE marker alone resolves omp.
test_omp_detection_ompcode_alone() {
  local out
  out=$(OMPCODE=1 "$HARNESS_BIN")
  [ "$out" = omp ] || fail "detect_own must return omp for the OMPCODE marker alone, got '$out'"
  pass "detect_own returns omp for the OMPCODE marker alone"
}

# Detection 3 (OPTIONAL): with no env marker, the Layer-2 ancestry walk matches a
# process whose comm is exactly omp. A fake ps drives the walk deterministically.
test_omp_detection_layer2_ancestry() {
  local dir fakebin out
  dir="$TMP_ROOT/detect-ancestry"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
# Fake ps for the ancestry walk: report the queried process as `omp`.
# detect_own queries `ps -o comm= -p PID`, `ps -o args= -p PID`, `ps -o ppid= -p PID`.
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf 'omp\n' ;;
  args=) printf 'omp --resume s1\n' ;;
  ppid=) printf '1\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  # Clear every Layer-1 marker so detection must fall through to the ps walk.
  out=$(env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" "$HARNESS_BIN")
  [ "$out" = omp ] || fail "detect_own Layer-2 must classify an omp comm ancestor as omp, got '$out'"
  pass "detect_own resolves omp via Layer-2 process ancestry when no env marker is set"
}

# --- crewmate / secondmate launch construction ------------------------------

# Spawn/crewmate 4 (REQUIRED): the captured launch is
# `omp --auto-approve ... -e '<state>/<id>.omp-ext.ts' "$(<opinput> encode launch-brief < '<brief>')"`.
test_omp_crewmate_launch_shape() {
  local rec id out status launch
  id=omp-crew-o4
  rec=$(make_spawn_case omp-crew omp "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "omp crewmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "omp --auto-approve" "omp crewmate launch missing base command + autonomy flag"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.omp-ext.ts'" \
    "omp crewmate launch missing the absolute -e turn-end signal extension"
  assert_contains "$launch" "\"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\"" \
    "omp crewmate launch missing the operational-input-encoded brief"
  pass "omp crewmate launch is omp --auto-approve + -e <state>/<id>.omp-ext.ts + encoded brief"
}

# Spawn/crewmate 5 (REQUIRED): the -e extension is written to the state override
# (outside the worktree), binds turn_end, and touches the task's turn-ended target.
test_omp_crewmate_writes_turnend_ext() {
  local rec id out status ompext
  id=omp-ext-o5
  rec=$(make_spawn_case omp-ext omp "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "omp crewmate spawn should succeed"
  ompext="$HOME_DIR/state/$id.omp-ext.ts"
  assert_present "$ompext" "omp turn-end signal must be written under FM_STATE_OVERRIDE, not the worktree"
  assert_grep 'pi.on("turn_end"' "$ompext" "omp ext must bind the crewmate turn_end signal"
  assert_grep "$id.turn-ended" "$ompext" "omp ext must touch the task's state/<id>.turn-ended target"
  pass "omp crewmate writes a state/<id>.omp-ext.ts turn_end signal referencing turn-ended"
}

# Spawn/secondmate 6 (REQUIRED): the secondmate launch keeps `omp --auto-approve`
# + brief but omits the -e signal extension, and no ext file is written for it.
test_omp_secondmate_launch_omits_ext() {
  local rec id sm out status launch
  id=omp-secondmate-o6
  rec=$(make_spawn_case omp-secondmate omp "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp kind=secondmate" \
    "omp secondmate launch did not resolve the omp harness"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "omp --auto-approve" "omp secondmate launch missing base command"
  assert_contains "$launch" "\"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < " \
    "omp secondmate launch missing the operational-input-encoded brief"
  assert_not_contains "$launch" ".omp-ext.ts" \
    "omp secondmate launch must omit the -e turn-end signal extension (guard auto-discovers)"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" \
    "omp secondmate must not write a crewmate turn-end signal extension"
  pass "omp secondmate launch omits the -e signal extension and writes no ext file"
}

# Runtime bound 6b (REQUIRED): config/omp-max-time is an opt-in per-home
# duration. Configured omp launches receive the exact flag, while an absent
# config keeps the previous unbounded launch. Unsupported values stop the spawn.
test_omp_threads_optional_max_time() {
  local rec id out status launch rec2 id2 status2 launch2 rec3 id3 out3 status3 help
  help=$("$SPAWN" --help)
  assert_contains "$help" "config/omp-max-time" \
    "fm-spawn help did not name the omp runtime-bound config"
  assert_contains "$help" "positive integer suffixed with \`m\` for minutes or \`h\` for hours" \
    "fm-spawn help did not define accepted omp max-time values"
  id=omp-max-time-o6b
  rec=$(make_spawn_case omp-max-time omp "$id")
  read_case_record "$rec"
  printf '# bounded crewmates\n  10m  \n' > "$HOME_DIR/config/omp-max-time"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "omp spawn with config/omp-max-time should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "omp --auto-approve --max-time=10m" \
    "configured omp launch did not thread --max-time"

  id2=omp-max-time-absent-o6c
  rec2=$(make_spawn_case omp-max-time-absent omp "$id2")
  read_case_record "$rec2"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id2" "$PROJ_DIR")
  status2=$?
  expect_code 0 "$status2" "omp spawn without config/omp-max-time should remain unbounded"
  launch2=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch2" "--max-time" \
    "unconfigured omp launch must omit --max-time"

  id3=omp-max-time-invalid-o6d
  rec3=$(make_spawn_case omp-max-time-invalid omp "$id3")
  read_case_record "$rec3"
  printf '0\n' > "$HOME_DIR/config/omp-max-time"
  out3=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id3" "$PROJ_DIR")
  status3=$?
  [ "$status3" -ne 0 ] || fail "invalid config/omp-max-time should stop the spawn"
  assert_contains "$out3" "must contain a positive integer" \
    "invalid max-time refusal did not explain accepted values"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "omp --auto-approve" \
    "invalid max-time config still reached the launch command"
  pass "omp threads configured max-time, omits it by default, and rejects invalid durations"
}

# Model 7 (REQUIRED): --model is threaded for a set model and absent by default.
test_omp_threads_model_flag() {
  local rec id out status launch rec2 id2 status2 launch2
  id=omp-model-o7
  rec=$(make_spawn_case omp-model omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model omp-fast)
  status=$?
  expect_code 0 "$status" "omp spawn with a model should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" omp omp-fast default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "omp --auto-approve --model 'omp-fast'" "omp launch did not thread --model"

  id2=omp-model-default-o7b
  rec2=$(make_spawn_case omp-model-default omp "$id2")
  read_case_record "$rec2"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id2" "$PROJ_DIR")
  status2=$?
  expect_code 0 "$status2" "omp spawn without a model should succeed"
  launch2=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch2" "--model" "omp default launch must omit --model"
  pass "omp threads --model when set and omits it by default"
}

# Role models 7b (REQUIRED): firstmate selects only the parent model and leaves
# omp's global modelRoles map authoritative for smol, slow, plan, and every role
# without a CLI flag. It also respects the captain's global prewalk setting.
test_omp_preserves_global_role_resolution() {
  local rec id out status launch
  id=omp-role-models-o7b
  rec=$(make_spawn_case omp-role-models omp "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 0 "$status" "omp spawn with a parent profile should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'openai-codex/gpt-5.6-sol'" \
    "omp launch did not select the requested parent model"
  assert_not_contains "$launch" "--smol" "omp launch must leave the global smol role authoritative"
  assert_not_contains "$launch" "--slow" "omp launch must leave the global slow role authoritative"
  assert_not_contains "$launch" "--plan" "omp launch must leave the global plan role authoritative"
  assert_not_contains "$launch" "--prewalk" "omp launch must respect the global prewalk setting"
  assert_not_contains "$launch" "--no-prewalk" "omp launch must not override an enabled global prewalk setting"
  pass "omp selects the parent profile without overriding global role models or prewalk"
}

# Effort 8 (REQUIRED): --thinking <effort> for low|medium|high|xhigh, never --effort.
test_omp_threads_thinking_effort() {
  local rec id out status launch rec2 id2 status2 launch2
  id=omp-effort-o8
  rec=$(make_spawn_case omp-effort omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort high)
  status=$?
  expect_code 0 "$status" "omp spawn with high effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" omp default high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--thinking 'high'" "omp launch did not thread --thinking high"
  assert_not_contains "$launch" "--effort" "omp must use --thinking, not --effort"

  id2=omp-effort-low-o8b
  rec2=$(make_spawn_case omp-effort-low omp "$id2")
  read_case_record "$rec2"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id2" "$PROJ_DIR" --effort low)
  status2=$?
  expect_code 0 "$status2" "omp spawn with low effort should succeed"
  launch2=$(cat "$LAUNCH_LOG")
  assert_contains "$launch2" "--thinking 'low'" "omp launch did not thread --thinking low"
  pass "omp threads --thinking for low/high effort and never falls back to --effort"
}

# Effort/max 9 (REQUIRED): omp 16.4.8 accepts max on the --thinking axis.
test_omp_threads_max_effort() {
  local rec id out status launch
  id=omp-max-o9
  rec=$(make_spawn_case omp-max omp "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model omp-fast --effort max)
  status=$?
  expect_code 0 "$status" "omp spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" omp omp-fast max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "omp --auto-approve --model 'omp-fast' --thinking 'max' -e" \
    "omp launch did not thread --thinking max after the 16.4.8 capability change"
  pass "omp threads the supported max thinking effort"
}

# Meta 10 (REQUIRED): state/<id>.meta records harness=omp.
test_omp_meta_records_harness() {
  local rec id out status
  id=omp-meta-o10
  rec=$(make_spawn_case omp-meta omp "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "omp spawn should record a meta profile"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" omp default default
  pass "omp spawn records harness=omp in state/<id>.meta"
}

# --- delivery-guard busy token (per-harness omp default + shared default) ---

# Pull the shipped default literal out of the adapter rather than hardcode it, so
# the test tracks whatever the adapter actually ships.
extract_tmux_busy_default() {
  sed -n "s/.*FM_TMUX_BUSY_REGEX_DEFAULT='\(.*\)'.*/\1/p" "$TMUX_LIB"
}

extract_tmux_omp_busy_default() {
  sed -n "s/.*FM_TMUX_OMP_BUSY_REGEX_DEFAULT='\(.*\)'.*/\1/p" "$TMUX_LIB"
}

# Busy 11 (REQUIRED): omp's per-harness delivery-guard token matches omp's ⟦esc⟧
# interrupt hint, ignores a clean idle line, and the shared ASCII "Working\.\.\."
# token does NOT match omp's unicode-ellipsis "Working…".
# This token is NOT a task-state source - bin/fm-busy-lib.sh's semantic contract
# owns task busy state. It serves only fm-tmux-lib.sh's delivery guards (fm-send
# submit acknowledgement and the away-mode supervisor-pane guard), so the
# assertions below are scoped to fm-tmux-lib.sh alone.
test_omp_busy_token_defaults() {
  local tmux_re omp_re
  tmux_re=$(extract_tmux_busy_default)
  omp_re=$(extract_tmux_omp_busy_default)
  [ -n "$tmux_re" ] || fail "could not extract FM_TMUX_BUSY_REGEX_DEFAULT from bin/fm-tmux-lib.sh"
  [ -n "$omp_re" ] || fail "could not extract FM_TMUX_OMP_BUSY_REGEX_DEFAULT from bin/fm-tmux-lib.sh"
  # omp busy: the bracketed interrupt hint rides both the thinking + tool phases.
  printf '%s\n' '⠧ Working… ⟦esc⟧' | grep -qiE "$omp_re" \
    || fail "omp busy signature must match omp's ⟦esc⟧ interrupt hint"
  # The shared default also carries omp's unambiguous ⟦esc⟧ so the harness-agnostic
  # composer/submit fallback (fm-send submit-ack, away-mode read) classifies omp busy.
  printf '%s\n' '⠧ Working… ⟦esc⟧' | grep -qiE "$tmux_re" \
    || fail "shared busy default must match omp's ⟦esc⟧ so the harness-agnostic fallback sees omp busy"
  # omp idle composer: rounded box, no busy footer.
  if printf '%s\n' '❯ ' | grep -qiE "$omp_re"; then
    fail "omp busy signature must not match a clean omp idle line"
  fi
  # NEGATIVE: omp's "Working…" uses U+2026, so the shared ASCII Working\.\.\. token
  # misses it - only the per-harness ⟦esc⟧ hint reliably classifies omp busy.
  if printf '%s\n' '⠧ Working…' | grep -qiE "$tmux_re"; then
    fail "shared busy default must not match omp's unicode-ellipsis Working… via the ASCII token"
  fi
  pass "omp delivery-guard token matches ⟦esc⟧, ignores idle, and the ASCII Working token misses unicode Working…"
}

# Busy 12 (REQUIRED, behavioral): omp classifies busy through the real
# fm_pane_is_busy -> fm_busy_lines_match dispatch, and omp's signature stays
# harness-scoped (a deleted omp case arm would fail here even if the literal
# default above still parsed).
test_omp_busy_signature_behavioral() {
  local capture
  # shellcheck source=/dev/null
  . "$TMUX_LIB"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/omp-busy-pane"
  # Invoked indirectly: fm_pane_is_busy shells out to `tmux capture-pane`, so
  # the call site is not statically visible here.
  # shellcheck disable=SC2329
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  printf '%s\n' '⠧ Working… ⟦esc⟧' > "$capture"
  fm_pane_is_busy fake omp || fail "omp's ⟦esc⟧ busy footer was not classified busy through fm_pane_is_busy"
  printf '%s\n' '❯ ' > "$capture"
  if fm_pane_is_busy fake omp; then
    fail "a clean omp idle composer was misread as busy"
  fi
  printf '%s\n' '⠧ Working… ⟦esc⟧' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "omp's ⟦esc⟧ signature leaked into codex's harness-scoped matcher"
  fi
  # No-box fallback path (allow_busy=1): an omp busy footer must classify empty
  # (Enter queued) so fm-send does not false-report a swallowed steer for omp.
  [ "$(fm_tmux_composer_row_state '⠧ Working… ⟦esc⟧' 0 1)" = empty ] \
    || fail "omp busy footer on the no-box fallback must classify empty (queued), not pending"
  unset -f tmux
  pass "fm_pane_is_busy classifies omp's ⟦esc⟧ footer busy, ignores idle, and does not leak across harnesses"
}

test_omp_detection_ompcode_beats_claudecode
test_omp_detection_ompcode_alone
test_omp_detection_layer2_ancestry
test_omp_crewmate_launch_shape
test_omp_crewmate_writes_turnend_ext
test_omp_secondmate_launch_omits_ext
test_omp_threads_optional_max_time
test_omp_threads_model_flag
test_omp_preserves_global_role_resolution
test_omp_threads_thinking_effort
test_omp_threads_max_effort
test_omp_meta_records_harness
test_omp_busy_token_defaults
test_omp_busy_signature_behavioral

echo "# all fm-omp-harness tests passed"
