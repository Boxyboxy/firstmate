#!/usr/bin/env bash
# Update the omp executable through the channel that currently owns it.
# Usage: fm-omp-update.sh [--check]
#
# A normal update is allowed only when this home has no recorded live fleet.
# --check performs omp's detect-only update check and does not require an empty
# fleet because it cannot replace the executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  printf '%s\n' 'usage: fm-omp-update.sh [--check]' >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

fleet_live_id() {
  local meta id
  [ -d "$STATE" ] || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

check_fleet_empty() {
  local id
  if id=$(fleet_live_id); then
    printf 'omp: refused: fleet is not empty (live task %s)\n' "$id" >&2
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
  check_fleet_empty
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
