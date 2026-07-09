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
  local fakebin=$1 comm=$2
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
  args=) printf '%s\n' '$comm --resume s1' ;;
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

test_fm_lock_recognizes_omp_ancestor
test_fm_lock_rejects_non_harness_ancestor

echo "# all fm-lock tests passed"
