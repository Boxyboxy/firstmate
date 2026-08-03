#!/usr/bin/env bash
# Update the omp executable through the channel that currently owns it.
# Usage: fm-omp-update.sh [--check]
#
# A normal update is allowed only when no worker is actually running in this
# home, because replacing the executable underneath one can break it mid-task.
# --check performs omp's detect-only update check and does not need that
# guarantee because it cannot replace the executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  printf '%s\n' 'usage: fm-omp-update.sh [--check]' >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# Is a worker actually running behind <meta-file>'s recorded endpoint?
# A metadata file's mere presence is not liveness: a persistent second mate
# keeps its record for its whole life whether or not it is running, and an
# interrupted cleanup can leave a record behind with nothing left to break.
# fm_backend_agent_state is the recovery-grade read, and only its confident
# `dead` and `missing` verdicts prove there is nothing running; every other
# verdict - including an endpoint that cannot be classified or is not recorded
# at all - counts as running, so an unreadable record never licenses a swap.
meta_endpoint_is_running() {
  local meta=$1 backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta" || true)
  [ -n "$target" ] || return 0
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 1 ;;
  esac
}

# Name the first running worker recorded in this home, in the captain's own
# nouns. A persistent second mate is never a task, so it is never labelled one.
running_worker() {
  local meta id
  [ -d "$STATE" ] || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    meta_endpoint_is_running "$meta" || continue
    id=$(basename "$meta" .meta)
    if grep -qx 'kind=secondmate' "$meta" 2>/dev/null; then
      printf 'second mate %s\n' "$id"
    else
      printf 'task %s\n' "$id"
    fi
    return 0
  done
  return 1
}

check_no_running_worker() {
  local worker
  if worker=$(running_worker); then
    printf 'omp: refused: a worker is still running (%s)\n' "$worker" >&2
    return 1
  fi
}

mode=update
case "${1:-}" in
  '') ;;
  --check) mode=check ;;
  --help|-h) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage; exit 2; }

omp_path=$(which omp 2>/dev/null) || {
  echo 'omp: unavailable on PATH' >&2
  exit 1
}
[ -x "$omp_path" ] || {
  echo "omp: resolved executable is not runnable: $omp_path" >&2
  exit 1
}

before=$("$omp_path" --version 2>/dev/null) || {
  echo "omp: could not read version from $omp_path" >&2
  exit 1
}
printf 'omp: channel: %s\n' "$omp_path"
printf 'omp: before: %s\n' "$(first_line "$before")"

if [ "$mode" = update ]; then
  check_no_running_worker
  if ! output=$("$omp_path" update 2>&1); then
    [ -z "$output" ] || printf '%s\n' "$output"
    echo 'omp: update failed' >&2
    exit 1
  fi
else
  if ! output=$("$omp_path" update --check 2>&1); then
    [ -z "$output" ] || printf '%s\n' "$output"
    echo 'omp: update check failed' >&2
    exit 1
  fi
fi
[ -z "$output" ] || printf '%s\n' "$output"

after=$("$omp_path" --version 2>/dev/null) || {
  echo "omp: could not read version after $mode from $omp_path" >&2
  exit 1
}
printf 'omp: after: %s\n' "$(first_line "$after")"
