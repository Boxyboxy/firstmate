#!/usr/bin/env bash
# tests/fm-lock.test.sh - bin/fm-lock.sh SESSION-lock harness-ancestry
# recognition (distinct from the watcher advisory lock in fm-watcher-lock.test.sh,
# which exercises fm-watch-arm.sh / fm-wake-lib.sh, not this script).
#
# fm-lock walks the process ancestry with `ps` looking for a known harness
# command name (HARNESS_RE) to find the long-lived agent PID that owns the
# per-home session lock; with no match it errors and the session runs read-only
# forever. This pins that omp is a recognized ancestor (anchored ^omp$, added
# when omp was verified), plus a non-harness control so the match is real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock)

# make_ancestry_ps <fakebin> <comm>: a fake ps that answers harness_pid()'s
# ancestry walk (ps -o comm=/-o args=/-o ppid= -p <pid>) as if the queried
# process were <comm>, with the parent chain terminating at pid 1.
make_ancestry_ps() {
  local fakebin=$1 comm=$2 args=${3:-"$2 --resume s1"}
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "\$field" in
  comm=) printf '%s\n' '$comm' ;;
  args=) printf '%s\n' '$args' ;;
  ppid=) printf '1\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
}

# fm-lock 12: an omp-named ancestor is recognized as the harness, so the session
# lock is acquired (an omp primary/secondmate would otherwise never hold it).
test_fm_lock_recognizes_omp_ancestor() {
  local dir state fakebin out status lock_pid
  dir="$TMP_ROOT/omp-ancestor"
  state="$dir/state"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$state"
  make_ancestry_ps "$fakebin" omp

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK")
  status=$?
  expect_code 0 "$status" "fm-lock should acquire when an omp-named ancestor is found"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not recognize the omp ancestor as a harness"
  assert_present "$state/.lock" "fm-lock did not write the session lock file"
  lock_pid=$(cat "$state/.lock")
  [ -n "$lock_pid" ] || fail "fm-lock wrote an empty session lock"
  pass "fm-lock.sh recognizes an omp-named ancestor and acquires the session lock"
}

# Control: a bare-shell ancestry is NOT a harness, so acquisition must fail. This
# proves the omp acceptance above is real recognition, not a ps that always matches
# (and that the fake-ps walk terminates as fm-lock expects).
test_fm_lock_rejects_non_harness_ancestor() {
  local dir state fakebin out status
  dir="$TMP_ROOT/non-harness-ancestor"
  state="$dir/state"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$state"
  make_ancestry_ps "$fakebin" zsh

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "fm-lock should fail when no harness ancestor exists"
  assert_contains "$out" "cannot locate harness process in ancestry" "fm-lock did not report the missing-harness error"
  assert_absent "$state/.lock" "fm-lock must not write a lock when no harness ancestor is found"
  pass "fm-lock.sh does not mistake a bare shell ancestor for a harness (control)"
}

# fm-lock 13: holder_alive() must match the holder's command name separately
# from its arguments, or anchored short names such as ^omp$ can never match.
test_fm_lock_preserves_live_omp_holder() {
  local dir state fakebin out status holder_pid
  dir="$TMP_ROOT/live-omp-holder"
  state="$dir/state"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$state"
  make_ancestry_ps "$fakebin" omp

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$state/.lock"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "fm-lock must not steal a live omp holder's lock"
  assert_contains "$out" "another live firstmate session holds the lock" "fm-lock did not report the live omp holder"
  [ "$(cat "$state/.lock")" = "$holder_pid" ] || fail "fm-lock overwrote the live omp holder"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid $holder_pid" "fm-lock status misreported the live omp holder"

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  pass "fm-lock.sh preserves and reports a live omp session holder"
}

test_fm_lock_recognizes_pi_interpreter_script() {
  local dir state fakebin out status
  dir="$TMP_ROOT/pi-interpreter"
  state="$dir/state"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$state"
  make_ancestry_ps "$fakebin" node 'node /usr/local/bin/pi --resume s1'

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1)
  status=$?
  expect_code 0 "$status" "fm-lock should recognize pi through the interpreter script path"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not recognize the pi interpreter script"
  pass "fm-lock.sh matches an interpreted harness by script basename without scanning prompt arguments"
}

test_fm_lock_recognizes_omp_ancestor
test_fm_lock_rejects_non_harness_ancestor
test_fm_lock_preserves_live_omp_holder
test_fm_lock_recognizes_pi_interpreter_script

echo "# all fm-lock tests passed"
