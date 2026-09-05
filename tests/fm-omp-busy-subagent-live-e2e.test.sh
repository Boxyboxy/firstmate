#!/usr/bin/env bash
# Opt-in live guard (live-harness-optin): the omp per-task busy extension that
# bin/fm-spawn.sh writes must attribute state/<id>.busy-state to the ROOT
# crewmate session only. omp hosts `task` subagents in the crewmate's own
# process and hands the same -e extension a factory call per child session, so
# a child's settled agent_end once wrote idle under the root's gen mid-run
# (2026-09-05). This guard runs the exact launch command fm-spawn builds in a
# real omp pane on a private tmux socket, has the root fan out one real
# subagent, and asserts the record never goes idle before the root's own
# completion, then goes idle exactly once after it. It exercises the installed
# omp and spends tokens; standard CI has neither, so it skips unless
# FM_OMP_LIVE_E2E=1. FM_OMP_LIVE_MODEL selects the model (default
# claude-haiku-4-5). docs/verification/supervision.md records the dated result.
set -u

if [ "${FM_OMP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LIVE_E2E=1 to run the real omp subagent busy-state guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OMP_BIN=$(command -v omp 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
[ -x "$OMP_BIN" ] || fail "FM_OMP_LIVE_E2E=1 but no real omp executable is installed on PATH"
[ -x "$REAL_TMUX" ] || fail "FM_OMP_LIVE_E2E=1 but tmux is not installed"
OMP_VERSION=$("$OMP_BIN" --version 2>/dev/null | head -1)
MODEL=${FM_OMP_LIVE_MODEL:-claude-haiku-4-5}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-busy-subagent-live)
SOCKET="fm-omp-busy-$$"
SAMPLER=
cleanup_live() {
  [ -z "$SAMPLER" ] || kill "$SAMPLER" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_live EXIT

ID=live-omp-child
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
LAUNCH_LOG="$TMP_ROOT/launch.log"
CHILD_RAN="$TMP_ROOT/child-ran"
ROOT_DONE="$TMP_ROOT/root-done"
SAMPLES="$TMP_ROOT/samples.log"

# The fake tmux captures the literal launch command fm-spawn would send to the
# pane; the real pane below runs that exact command.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
      prev=$a
    done
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" treehouse

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'omp\n' > "$HOME_DIR/config/crew-harness"
fm_git_worktree "$PROJ" "$WT" "wt-$ID"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
Use the task tool exactly once to spawn one subagent whose task is: run the bash command \`touch '$CHILD_RAN'\`, then reply with the single word PONG and nothing else.
After the subagent returns, run the bash command \`touch '$ROOT_DONE'\`, then reply with exactly: DONE
Use no other tools.
Delivery contract: mode=no-mistakes
EOF

: > "$LAUNCH_LOG"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN:$PATH" \
  "$SPAWN" "$ID" "$PROJ" --mode no-mistakes --yolo off --model "$MODEL" --effort low 2>&1)
expect_code 0 $? "omp spawn should succeed: $out"
STATE="$HOME_DIR/state"
LAUNCH=$(head -1 "$LAUNCH_LOG")
[ -n "$LAUNCH" ] || fail "fm-spawn sent no launch command"
case "$LAUNCH" in
  omp\ *) ;;
  *) fail "captured launch is not an omp command: $LAUNCH" ;;
esac
out=$(fm_busy_classify tmux fake:w omp "$ID" "$STATE")
[ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

# One sequential poller records busy-state transitions and the two completion
# markers in causal order, so the assertions below need no clock comparison.
(
  last=; child=0; root=0
  while :; do
    cur=$(cat "$STATE/$ID.busy-state" 2>/dev/null)
    if [ "$cur" != "$last" ]; then
      printf 'record %s\n' "$cur" >> "$SAMPLES"
      last=$cur
    fi
    if [ "$child" = 0 ] && [ -e "$CHILD_RAN" ]; then printf 'marker child-ran\n' >> "$SAMPLES"; child=1; fi
    if [ "$root" = 0 ] && [ -e "$ROOT_DONE" ]; then printf 'marker root-done\n' >> "$SAMPLES"; root=1; fi
    sleep 0.1
  done
) &
SAMPLER=$!

"$REAL_TMUX" -L "$SOCKET" new-session -d -s w -x 200 -y 50 -c "$WT" "$LAUNCH" \
  || fail "could not launch the real omp pane"

for _ in $(seq 1 1800); do
  [ -e "$ROOT_DONE" ] && break
  "$REAL_TMUX" -L "$SOCKET" has-session -t w 2>/dev/null || break
  sleep 0.1
done
[ -e "$ROOT_DONE" ] || fail "omp $OMP_VERSION never reached the root completion marker; pane tail: $("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t w 2>/dev/null | grep -v '^$' | tail -12)"
[ -e "$CHILD_RAN" ] || fail "omp $OMP_VERSION finished the root turn without the subagent ever running, so this guard checked nothing"

# The root's own idle edge lands within a second of its final agent_end.
for _ in $(seq 1 300); do
  grep -q 'state=idle' "$SAMPLES" 2>/dev/null && break
  sleep 0.1
done
sleep 2
kill "$SAMPLER" 2>/dev/null || true
SAMPLER=

before_root=$(sed '/^marker root-done$/,$d' "$SAMPLES")
after_root=$(sed -n '/^marker root-done$/,$p' "$SAMPLES")
printf '%s\n' "$before_root" | grep -q '^marker child-ran$' \
  || fail "omp $OMP_VERSION: the subagent marker did not precede the root completion marker; samples: $(cat "$SAMPLES")"
printf '%s\n' "$before_root" | grep -q 'source=omp-ext event=agent-start' \
  || fail "omp $OMP_VERSION: the root's agent_start never reached the record; samples: $(cat "$SAMPLES")"
if printf '%s\n' "$before_root" | grep -q 'state=idle'; then
  fail "omp $OMP_VERSION: the record went idle while the root was still working (a child session's agent_end reached the root's record); samples: $(cat "$SAMPLES")"
fi
idle_after=$(printf '%s\n' "$after_root" | grep -c 'state=idle')
[ "$idle_after" = 1 ] || fail "omp $OMP_VERSION: expected exactly one idle after root completion, got $idle_after; samples: $(cat "$SAMPLES")"
out=$(fm_busy_classify tmux fake:w omp "$ID" "$STATE")
[ "$out" = "idle omp-ext" ] || fail "omp $OMP_VERSION: final classification must be 'idle omp-ext', got '$out'"

"$REAL_TMUX" -L "$SOCKET" send-keys -t w -l '/quit' 2>/dev/null || true
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t w Enter 2>/dev/null || true
pass "omp $OMP_VERSION: a real task subagent's completion left the root's record busy, and only the root's completion settled it idle"
