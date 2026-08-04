#!/usr/bin/env bash
# Update the omp executable through the channel that currently owns it.
# Usage: fm-omp-update.sh [--check]
#
# omp is ONE machine-wide executable, so replacing it can break any worker
# running on this machine - not only this home's. A normal update is therefore
# allowed only when every worker recorded in this home AND in every local
# second mate home has confidently stopped. A second mate reached over SSH runs
# its workers on another machine, where this machine's omp cannot break
# anything, so neither its route nor its local proxy record is part of this
# sweep, in either the home collection or the record classification.
# --check performs omp's detect-only update check and does not need that
# guarantee because it cannot replace the executable.
#
# Two entry points, and only one of them may install:
#   - the LIVE update path, step 4 of the /updatefirstmate skill
#     (.agents/skills/updatefirstmate/SKILL.md), runs this with no arguments so
#     the recurring refresh actually swaps omp once the gate says the fleet is
#     stopped. That skill owns the operator-facing contract.
#   - the unattended overnight omp-firstmate-leverage cron runs it as `--check`
#     only. It is deliberately detect-only: with nobody present to read a
#     refusal, it reports what is available and never installs.
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
  printf '%s\n' 'usage: fm-omp-update.sh [--check]' >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

meta_is_secondmate() {  # <meta-file>
  grep -qx 'kind=secondmate' "$1" 2>/dev/null
}

# A record whose worker runs on another machine over SSH. This machine's omp
# cannot break it, and its recorded window is a local-looking proxy selector
# with no backend field, so classifying it against a LOCAL backend would answer
# a question about the wrong machine.
meta_is_remote_route() {  # <meta-file>
  grep -q '^remote_host=.' "$1" 2>/dev/null
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
# refusal says exactly what remains unproven.
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
#
# A place this sweep cannot reach is unproven, exactly like an endpoint that
# cannot be classified, so it is recorded in SWEEP_UNREACHABLE and reported as
# an unconfirmed blocker instead of being silently counted as empty. "Has no
# records yet" and "cannot be reached" are therefore separated at the HOME, not
# at the state dir: a home that resolves proves the sweep got there, so its
# absent state dir really is an empty home, while a home that does not resolve -
# missing, not a directory, or unsearchable - proves nothing and is reported.
# A state path that EXISTS but is not a readable directory - a regular file, a
# dangling symlink, an unsearchable one - is the same unproven case: the sweep
# reached something and still read no records, so it never counts as empty.
SWEEP_DIRS=""
SWEEP_SEEN=" "
SWEEP_UNREACHABLE=""

note_unreachable() {  # <what> <reason>
  SWEEP_UNREACHABLE="$SWEEP_UNREACHABLE$1: $2
"
}

add_sweep_state() {  # <state-dir> <owner-label>
  local dir=$1 owner=$2 resolved
  [ -n "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      note_unreachable "${owner:-this home}" \
        "its local records at $dir are not a readable directory"
    fi
    return 0
  fi
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) || {
    note_unreachable "${owner:-this home}" "its local records at $dir cannot be read"
    return 0
  }
  case "$SWEEP_SEEN" in *" $resolved "*) return 0 ;; esac
  SWEEP_SEEN="$SWEEP_SEEN$resolved "
  SWEEP_DIRS="$SWEEP_DIRS$resolved	$owner
"
}

add_sweep_home() {  # <home> <owner-label> [state-dir]
  local home=$1 owner=$2 state=${3:-} resolved
  case "$home" in
    /*) ;;
    *)
      note_unreachable "${owner:-this home}" "its recorded location is not a usable path (${home:-empty})"
      return 0
      ;;
  esac
  resolved=$(cd "$home" 2>/dev/null && pwd -P) || {
    note_unreachable "${owner:-this home}" \
      "its recorded location $home is missing or cannot be read, so its records could not be swept"
    return 0
  }
  add_sweep_state "${state:-$resolved/state}" "$owner"
}

collect_sweep_dirs() {
  local meta id home line
  SWEEP_DIRS=""
  SWEEP_SEEN=" "
  SWEEP_UNREACHABLE=""
  add_sweep_home "$FM_HOME" "" "$STATE"
  if [ -d "$STATE" ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      meta_is_secondmate "$meta" || continue
      if meta_is_remote_route "$meta"; then continue; fi
      id=$(basename "$meta" .meta)
      home=$(fm_meta_get "$meta" home)
      add_sweep_home "$home" "second mate $id's home"
    done
  fi
  if [ -f "$SECONDMATES_MD" ] && [ ! -L "$SECONDMATES_MD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      if ! secondmate_registry_parse_line "$line"; then
        note_unreachable "the second mate registry" \
          "its entry \"$line\" could not be read, so that home could not be swept"
        continue
      fi
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
      add_sweep_home "$SECONDMATE_REGISTRY_HOME" "second mate $SECONDMATE_REGISTRY_ID's home"
    done < "$SECONDMATES_MD"
  elif [ -e "$SECONDMATES_MD" ] || [ -L "$SECONDMATES_MD" ]; then
    note_unreachable "the second mate registry" "$SECONDMATES_MD is not a plain file, so registered homes could not be swept"
  fi
}

# Name the first record that blocks a swap, in the captain's own nouns, and say
# which class of blocker it is. A persistent second mate is never a task, so it
# is never labelled one. A verifiably running worker outranks a merely
# unclassified one, so the sweep keeps looking after the first unclassified
# record and reports the strongest evidence it found, and a place the sweep
# could not reach at all is weighed last as unconfirmed.
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
      if meta_is_remote_route "$meta"; then continue; fi
      out=$(meta_endpoint_class "$meta" </dev/null)
      class=${out%% *}
      reason=${out#* }
      [ "$class" != stopped ] || continue
      id=$(basename "$meta" .meta)
      if meta_is_secondmate "$meta"; then
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
  if [ -z "$BLOCK_KIND" ] && [ -n "$SWEEP_UNREACHABLE" ]; then
    BLOCK_KIND=unclassified
    BLOCK_WHAT=$(printf '%s' "$SWEEP_UNREACHABLE" | sed -n '1p')
  fi
  [ -n "$BLOCK_KIND" ]
}

gate_allows_update() {
  collect_sweep_dirs
  find_blocker || return 0
  if [ "$BLOCK_KIND" = running ]; then
    printf 'omp: refused: a worker is still running (%s)\n' "$BLOCK_WHAT" >&2
  else
    printf 'omp: refused: could not confirm every worker has stopped (%s)\n' \
      "$BLOCK_WHAT" >&2
  fi
  return 1
}

mode=update
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

omp_path=$(command -v omp 2>/dev/null) || {
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
