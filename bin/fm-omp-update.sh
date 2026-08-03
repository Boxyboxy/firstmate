#!/usr/bin/env bash
# Update the omp executable through the channel that currently owns it.
# Usage: fm-omp-update.sh [--check] [--force]
#
# omp is ONE machine-wide executable, so replacing it can break any worker
# running on this machine - not only this home's. A normal update is therefore
# allowed only when every worker recorded in this home AND in every local
# second mate home has confidently stopped. A second mate reached over SSH runs
# its workers on another machine, where this machine's omp cannot break
# anything, so its route is deliberately not part of this sweep.
# --check performs omp's detect-only update check and does not need that
# guarantee because it cannot replace the executable.
# --force is the operator's explicit override, for the case where a backend has
# no recovery-grade liveness classifier (the experimental backends) or an
# endpoint read keeps failing, which would otherwise leave the update wedged
# with no way through. It names what it overrode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  printf '%s\n' 'usage: fm-omp-update.sh [--check] [--force]' >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# Classify what <meta-file>'s recorded endpoint proves, as "<class> <reason>":
#   stopped      - nothing is running behind it, so omp cannot break it.
#   running      - a harness agent is verifiably there.
#   unclassified - it could not be read or this backend has no recovery-grade
#                  classifier, so nothing is proven either way.
# A metadata file's mere presence is not liveness: a persistent second mate
# keeps its record for its whole life whether or not it is running, and an
# interrupted cleanup can leave a record behind with nothing left to break.
# fm_backend_agent_state is the recovery-grade read, and only its confident
# `dead` and `missing` verdicts prove there is nothing running. Everything else
# stays unclassified rather than being reported as a running worker, so the
# refusal says what is actually known and points at the override.
meta_endpoint_class() {
  local meta=$1 backend target verdict
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta" || true)
  if [ -z "$target" ]; then
    printf 'unclassified no endpoint is recorded'
    return 0
  fi
  verdict=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
  case "$verdict" in
    dead|missing) printf 'stopped %s' "$verdict" ;;
    alive) printf 'running alive' ;;
    *) printf 'unclassified its %s endpoint reads %s' "$backend" "${verdict:-nothing}" ;;
  esac
}

# Every state directory this gate must account for, one tab-separated
# "<dir>\t<owner>" record per line, where <owner> is empty for this home. The
# registry forbids tabs in a home path, so the field split is unambiguous.
# Second mate homes come from this home's own kind=secondmate records and from
# the registry, so a second mate that is registered but not currently recorded
# live is still swept.
SWEEP_DIRS=""
SWEEP_SEEN=" "

add_sweep_state() {  # <state-dir> <owner-label>
  local dir=$1 owner=$2 resolved
  [ -n "$dir" ] || return 0
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  case "$SWEEP_SEEN" in *" $resolved "*) return 0 ;; esac
  SWEEP_SEEN="$SWEEP_SEEN$resolved "
  SWEEP_DIRS="$SWEEP_DIRS$resolved	$owner
"
}

add_sweep_home() {  # <home> <owner-label>
  local home=$1 owner=$2
  case "$home" in /*) ;; *) return 0 ;; esac
  add_sweep_state "$home/state" "$owner"
}

collect_sweep_dirs() {
  local meta id home line
  SWEEP_DIRS=""
  SWEEP_SEEN=" "
  add_sweep_state "$STATE" ""
  if [ -d "$STATE" ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -qx 'kind=secondmate' "$meta" 2>/dev/null || continue
      if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
      id=$(basename "$meta" .meta)
      home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      add_sweep_home "$home" "second mate $id's home"
    done
  fi
  if [ -f "$SECONDMATES_MD" ] && [ ! -L "$SECONDMATES_MD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
      add_sweep_home "$SECONDMATE_REGISTRY_HOME" "second mate $SECONDMATE_REGISTRY_ID's home"
    done < "$SECONDMATES_MD"
  fi
}

# Name the first record that blocks a swap, in the captain's own nouns, and say
# which class of blocker it is. A persistent second mate is never a task, so it
# is never labelled one. A verifiably running worker outranks a merely
# unclassified one, so the sweep keeps looking after the first unclassified
# record and reports the strongest evidence it found.
BLOCK_KIND=""
BLOCK_WHAT=""

find_blocker() {
  local dir owner meta id class reason label out
  BLOCK_KIND=""
  BLOCK_WHAT=""
  while IFS=$'\t' read -r dir owner; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] || continue
      out=$(meta_endpoint_class "$meta")
      class=${out%% *}
      reason=${out#* }
      [ "$class" != stopped ] || continue
      id=$(basename "$meta" .meta)
      if grep -qx 'kind=secondmate' "$meta" 2>/dev/null; then
        label="second mate $id"
      else
        label="task $id"
      fi
      [ -z "$owner" ] || label="$label in $owner"
      if [ "$class" = running ]; then
        BLOCK_KIND=running
        BLOCK_WHAT="$label"
        return 0
      fi
      if [ -z "$BLOCK_KIND" ]; then
        BLOCK_KIND=unclassified
        BLOCK_WHAT="$label: $reason"
      fi
    done
  done <<EOF
$SWEEP_DIRS
EOF
  [ -n "$BLOCK_KIND" ]
}

gate_allows_update() {
  collect_sweep_dirs
  find_blocker || return 0
  if [ "$force" = yes ]; then
    if [ "$BLOCK_KIND" = running ]; then
      printf 'omp: forced past a worker that is still running (%s)\n' "$BLOCK_WHAT" >&2
    else
      printf 'omp: forced past a worker whose state could not be confirmed (%s)\n' "$BLOCK_WHAT" >&2
    fi
    return 0
  fi
  if [ "$BLOCK_KIND" = running ]; then
    printf 'omp: refused: a worker is still running (%s)\n' "$BLOCK_WHAT" >&2
  else
    printf 'omp: refused: could not confirm every worker has stopped (%s); rerun with --force once you know nothing is running\n' \
      "$BLOCK_WHAT" >&2
  fi
  return 1
}

mode=update
force=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --force) force=yes ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [ "$mode" = check ] && [ "$force" = yes ]; then
  echo 'omp: --force does not apply to --check, which never replaces the executable' >&2
  exit 2
fi

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
  gate_allows_update
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
