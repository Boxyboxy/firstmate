#!/usr/bin/env bash
# Behavior tests for the shared bounded-execution owner (bin/fm-timeout-lib.sh).
#
# Every mechanism the host provides is exercised, because fm_run_timed picks one
# at run time and a fidelity bug in one is invisible on a host that picks
# another. Coreutils/BSD `timeout` is absent on stock macOS, so perl is the
# default there while Linux runners take the `timeout` branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)
mkdir -p "$TMP_ROOT"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Every mechanism this host can really run. bash needs nothing; the others need
# their own binary, and a machine missing one must not silently pass over it.
MECHANISMS=bash
for tool in timeout gtimeout perl; do
  command -v "$tool" >/dev/null 2>&1 && MECHANISMS="$MECHANISMS $tool"
done
[ "$(fm_timeout_mechanism)" != bash ] || [ "$MECHANISMS" = bash ] \
  || fail "the selector chose bash while $MECHANISMS are available"

# Run <command...> under exactly <mechanism> and echo the status fm_run_timed
# returned. The selector is a documented function, so forcing it drives the real
# branch rather than whichever one this host would have picked.
run_under() {  # <mechanism> <seconds> <command...>
  local mech=$1 seconds=$2 rc
  shift 2
  set +e
  (
    eval "fm_timeout_mechanism() { printf '%s\n' '$mech'; }"
    fm_run_timed "$seconds" "$@"
  )
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

# --- the command's own status survives the bound ------------------------------

for mech in $MECHANISMS; do
  rc=$(run_under "$mech" 30 bash -c 'exit 0')
  [ "$rc" -eq 0 ] || fail "$mech: a clean command reported $rc instead of 0"
  rc=$(run_under "$mech" 30 bash -c 'exit 7')
  [ "$rc" -eq 7 ] || fail "$mech: an ordinary failure reported $rc instead of 7"
done
pass "fm_run_timed preserves an ordinary exit status under every available mechanism ($MECHANISMS)"

# --- a signal-killed command is never reported as a clean exit ----------------

# perl's `$? >> 8` alone reports 0 for a signalled child, which would turn a
# crash into a pass for every caller - most visibly the behavior-test runner,
# where a segfaulting test script would be counted green.
cat >"$TMP_ROOT/crash.sh" <<'SH'
#!/usr/bin/env bash
kill -SEGV $$
SH
chmod +x "$TMP_ROOT/crash.sh"
DIRECT=$(
  set +e
  bash "$TMP_ROOT/crash.sh" 2>/dev/null
  printf '%s\n' "$?"
)
[ "$DIRECT" -gt 128 ] \
  || fail "the unbounded baseline did not report 128+signal for a killed command (got $DIRECT)"
for mech in $MECHANISMS; do
  rc=$(run_under "$mech" 30 bash "$TMP_ROOT/crash.sh" 2>/dev/null)
  [ "$rc" -ne 0 ] || fail "$mech: a signal-killed command was reported as a clean exit"
  [ "$rc" -eq "$DIRECT" ] \
    || fail "$mech: a signal-killed command reported $rc, not the shell's own $DIRECT"
done
pass "fm_run_timed reports 128+signal for a killed command instead of a false success"

# --- the bound itself ---------------------------------------------------------

for mech in $MECHANISMS; do
  rc=$(run_under "$mech" 1 bash -c 'sleep 60')
  [ "$rc" -eq 124 ] || fail "$mech: hitting the bound reported $rc instead of 124"
done
pass "fm_run_timed reports 124 when the bound is hit, under every available mechanism"

# A hung grandchild must not outlive the bound: the whole process group goes.
for mech in $MECHANISMS; do
  pidfile="$TMP_ROOT/grandchild-$mech.pid"
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  rc=$(run_under "$mech" 1 bash -c '
    bash -c "exec sleep 300" &
    printf "%s\n" "$!" > "$1"
    sleep 300
  ' _ "$pidfile")
  [ "$rc" -eq 124 ] || fail "$mech: the grandchild case did not report the bound (got $rc)"
  [ -s "$pidfile" ] || fail "$mech: the fixture never recorded its grandchild pid"
  child=$(cat "$pidfile")
  waited=0
  while kill -0 "$child" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "$mech: the bound left grandchild $child alive"
  fi
done
pass "fm_run_timed terminates the whole process group, so a hung grandchild cannot outlive the bound"

echo "ALL TESTS PASSED"
