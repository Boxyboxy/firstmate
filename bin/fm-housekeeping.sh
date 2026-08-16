#!/usr/bin/env bash
# fm-housekeeping.sh - reclaim disk left behind by finished crew work without
# touching anything still in use.
#
# Usage:
#   fm-housekeeping.sh                    dry run: report what would be reclaimed
#   fm-housekeeping.sh --apply            reclaim it
#   fm-housekeeping.sh --apply --images   also remove unused images (opt-in)
#   fm-housekeeping.sh --keep <pattern>   protect a container name or name* prefix
#   fm-housekeeping.sh --keep <dir>       protect every container a stack directory claims
#   fm-housekeeping.sh --no-worktrees     skip the worktree phase
#   fm-housekeeping.sh --help
#
# Dry run is the default and deletes nothing. --apply is the only delete path.
#
# --- why this script exists in this shape -----------------------------------
#
# A manual sweep once built its protection list with
#   docker ps -q --format '{{.Names}}' | grep -v '^wffui-' | xargs -r docker rm -f
# Docker prints "WARNING: Ignoring custom format, because both --format and
# --quiet are set" and emits container IDs. The grep therefore matched nothing,
# and the pipeline removed all 17 running containers including a live captain
# stack serving four ports. Every listing below uses --format WITHOUT -q for
# exactly that reason, and the delete path is built so that a filter matching
# nothing yields an EMPTY kill-list instead of everything.
#
# --- how a container is classified ------------------------------------------
#
# Kill-lists are built by POSITIVE selection: a container is removed only when
# this script can say whose finished work it belongs to, or (when stopped) can
# see that nothing protects it. Each container is tested in this fixed order and
# stops at the first verdict:
#
#   1. keep:configured    - name matches the configured keep-list (below).
#   2. keep:live-task     - name, compose project, or compose working_dir carries
#                           the id of a task with a live state/<id>.meta.
#   3. keep:serving       - running with a published host port. Docker binds that
#                           port for as long as the container runs, so the port
#                           binding itself is the structural in-use signal; no
#                           name prefix is consulted.
#   4. keep:stack-claimed - its compose working_dir exists on disk and holds a
#                           stack manifest (stack.sh, compose.sh, or a compose
#                           yaml), so something on disk still claims it.
#   5. orphan             - the same match against a KNOWN but finished task id
#                           (a data/<id>/ directory with no state/<id>.meta).
#                           Running orphans are removed only under --apply.
#   6. keep:unattributed  - running and none of the above: KEPT and reported for
#                           the captain to judge. Unattributable is never a
#                           delete reason.
#   7. reclaim:stopped    - stopped, unprotected, and in no protected compose
#                           project. A stopped container is doing nothing now,
#                           and one a live stack owns is protected by 1, 2, 3, 4,
#                           or by project propagation below.
#
# Protection propagates across a compose project: if any member is kept by 1, 2,
# 3, or 4, every member of that project is kept, so a stack with one stopped
# member never loses it.
#
# --- the two delete-path refusals -------------------------------------------
#
#   * Immediately before any removal, the kill-list is intersected BY NAME with
#     the keep-list. A non-empty intersection refuses the whole run.
#   * If running containers exist and the run concluded that NONE of them should
#     be kept, it refuses. That is the incident above in its general form: a
#     sweep that decides to remove every running container is wrong.
#
# --- phase order -------------------------------------------------------------
#
# Ascending cost to re-acquire, so a run interrupted partway has spent the
# cheapest reclaim first:
#
#   1. worktrees        - `treehouse prune --all` (dry) / `--all --yes` (apply).
#                         Treehouse's own refusal to prune a worktree with
#                         uncommitted changes is never overridden and
#                         --prune-orphans is never passed.
#   2. stopped containers
#   3. dangling volumes - the shared dry/apply mutation model lists volumes with
#                         `docker volume ls --filter dangling=true --filter
#                         label=com.docker.volume.anonymous --format
#                         '{{.Name}}'` twice, 30 seconds apart, and removes only
#                         names present in both samples. Protected mounts are
#                         the union of observations immediately before and after
#                         the first sample and remain excluded for the run. The
#                         phase aborts if protected work is non-running at either
#                         sample.
#   4. build cache      - `docker builder prune -f`.
#   5. orphaned running containers of finished tasks.
#   6. dangling volumes again - repeat the two-sample removal after orphan
#                         removal because its volumes become dangling only once
#                         the container is gone. Skipping this rerun cost a real
#                         sweep 1.3 GB after it had already reclaimed 42.3 GB.
#   7. unused images    - `docker image prune -a -f`, only with --images. Largest
#                         reclaim, most expensive to get back, and the base
#                         images live stacks rebuild from are among them.
#
# Under --apply, every container name kept by this run is re-checked afterwards
# and any that stopped is reported as a verification failure. Free space is
# reported before and after.
#
# --- configured keep-list ----------------------------------------------------
#
# $FM_HOME/config/housekeeping-keep, one entry per line, # comments allowed:
#   <name>       protect exactly this container name
#   <name>*      protect every container name with this prefix
#   /abs/path    a stack directory: protect every container whose compose
#                working_dir is at or under it, and every container named
#                literally in a stack.sh, compose.sh, or compose yaml there
# --keep <pattern> adds an entry for one run. The configured list is a second
# line of defence behind the structural signals, never the only one.
#
# Environment:
#   FM_HOME                 home whose state/ and data/ define live and finished
#                           work (default: this repo root)
#   FM_HOUSEKEEPING_DF_PATH filesystem sampled for free space (default: /)
#   FM_HOUSEKEEPING_VOLUME_STABILITY_SECONDS
#                           delay between dangling-volume samples (default: 30)
#
# Exit status: 0 completed; 1 an underlying command failed; 2 invalid use;
# 3 refused for safety without deleting anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="$FM_HOME/data"
STATE="$FM_HOME/state"
KEEP_FILE="$FM_HOME/config/housekeeping-keep"
DF_PATH="${FM_HOUSEKEEPING_DF_PATH:-/}"
VOLUME_STABILITY_SECONDS="${FM_HOUSEKEEPING_VOLUME_STABILITY_SECONDS:-30}"

usage() {
  sed -n '2,115{s/^#$//;s/^# \{0,1\}//;p;}' "$0"
}

if ! [[ "$VOLUME_STABILITY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'fm-housekeeping: FM_HOUSEKEEPING_VOLUME_STABILITY_SECONDS must be non-negative\n' >&2
  exit 2
fi

APPLY=0
IMAGES=0
WORKTREES=1
CLI_KEEP=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --apply) APPLY=1 ;;
    --images) IMAGES=1 ;;
    --no-worktrees) WORKTREES=0 ;;
    --keep)
      [ "$#" -ge 2 ] || { printf 'fm-housekeeping: --keep needs a value\n' >&2; exit 2; }
      CLI_KEEP+=("$2"); shift ;;
    *) printf 'fm-housekeeping: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

EXIT=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fm-housekeeping.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

note() { printf '%s\n' "$*"; }
warn() { printf 'fm-housekeeping: %s\n' "$*" >&2; }

refuse() {
  printf '\nREFUSED: %s\n' "$*" >&2
  printf 'Nothing was deleted.\n' >&2
  exit 3
}

have() { command -v "$1" >/dev/null 2>&1; }

free_gb() {
  # POSIX df blocks are 1K here; report one decimal so a small reclaim is visible.
  df -k "$DF_PATH" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1048576}'
}

# contains_token <haystack> <token>: token appears delimited by non-alphanumerics
# or at a boundary. Task ids are slugs that may themselves contain dashes, so the
# haystack is padded rather than split.
contains_token() {
  case "-$1-" in
    *[!A-Za-z0-9]"$2"[!A-Za-z0-9]*) return 0 ;;
  esac
  return 1
}

# --- inputs ------------------------------------------------------------------

: >"$WORK/live-ids"
: >"$WORK/done-ids"
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id="$(basename "$meta" .meta)"
    printf '%s\n' "$id" >>"$WORK/live-ids"
  done
fi
if [ -d "$DATA" ]; then
  for dir in "$DATA"/*/; do
    [ -d "$dir" ] || continue
    id="$(basename "$dir")"
    grep -qxF "$id" "$WORK/live-ids" && continue
    printf '%s\n' "$id" >>"$WORK/done-ids"
  done
fi

: >"$WORK/keep-patterns"
: >"$WORK/keep-dirs"
load_keep_entry() {
  case "$1" in
    ''|'#'*) return 0 ;;
    /*) printf '%s\n' "${1%/}" >>"$WORK/keep-dirs" ;;
    *) printf '%s\n' "$1" >>"$WORK/keep-patterns" ;;
  esac
}
if [ -f "$KEEP_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    load_keep_entry "${line%%#*}"
  done <"$KEEP_FILE"
fi
for entry in ${CLI_KEEP[@]+"${CLI_KEEP[@]}"}; do
  load_keep_entry "$entry"
done

# Names a configured stack directory claims: compose working_dir matches, or the
# name appears literally in a manifest there.
: >"$WORK/keep-dir-names"
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ -d "$dir" ] || continue
  for manifest in "$dir"/stack.sh "$dir"/compose.sh "$dir"/compose.yml "$dir"/compose.yaml \
    "$dir"/docker-compose.yml "$dir"/docker-compose.yaml; do
    [ -f "$manifest" ] || continue
    printf '%s\n' "$manifest" >>"$WORK/keep-manifests"
  done
done <"$WORK/keep-dirs"

matches_keep_pattern() { # <name>
  local name="$1" pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in
      *'*') case "$name" in ${pat%\*}*) return 0 ;; esac ;;
      *) [ "$name" = "$pat" ] && return 0 ;;
    esac
  done <"$WORK/keep-patterns"
  return 1
}

claimed_by_keep_dir() { # <name> <working_dir>
  local name="$1" wd="$2" dir manifest
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$wd" in "$dir"|"$dir"/*) return 0 ;; esac
  done <"$WORK/keep-dirs"
  [ -f "$WORK/keep-manifests" ] || return 1
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    grep -qF -- "$name" "$manifest" && return 0
  done <"$WORK/keep-manifests"
  return 1
}

has_stack_manifest() { # <dir>
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  for manifest in stack.sh compose.sh compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    [ -f "$dir/$manifest" ] && return 0
  done
  return 1
}

match_task_id() { # <name> <project> <working_dir> <label-task>; echoes "live|done <id>"
  local hay="$1 $2 $3" label="$4" id best_live='' best_done=''
  if [ -n "$label" ]; then
    if grep -qxF "$label" "$WORK/live-ids"; then printf 'live %s\n' "$label"; return 0; fi
    if grep -qxF "$label" "$WORK/done-ids"; then printf 'done %s\n' "$label"; return 0; fi
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    contains_token "$hay" "$id" || continue
    [ "${#id}" -gt "${#best_live}" ] && best_live="$id"
  done <"$WORK/live-ids"
  if [ -n "$best_live" ]; then printf 'live %s\n' "$best_live"; return 0; fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    contains_token "$hay" "$id" || continue
    [ "${#id}" -gt "${#best_done}" ] && best_done="$id"
  done <"$WORK/done-ids"
  [ -n "$best_done" ] && printf 'done %s\n' "$best_done"
  return 0
}

# --- container inventory -----------------------------------------------------
#
# NEVER add -q here. See the header: -q makes docker ignore --format and emit
# IDs, which silently turns a name filter into a match-everything filter.
DOCKER_FMT='{{.Names}}|{{.State}}|{{.Label "com.docker.compose.project"}}|{{.Label "dev.firstmate.task"}}|{{.Ports}}|{{.Label "com.docker.compose.project.working_dir"}}'

DOCKER_OK=0
: >"$WORK/inventory"
if have docker; then
  if docker ps -a --format "$DOCKER_FMT" >"$WORK/inventory" 2>"$WORK/docker-err"; then
    DOCKER_OK=1
  else
    warn "docker is installed but not answering: $(tr '\n' ' ' <"$WORK/docker-err")"
    EXIT=1
  fi
else
  warn 'docker is not installed; skipping every container, volume, cache, and image phase'
fi

# An inventory this script cannot parse is the incident's general form: a
# listing that lost its shape must never be classified, because every
# unrecognized line would fall through to a delete verdict. Validate the shape
# first and treat any deviation as a hard stop rather than a classification
# input. `wd` is last and may itself contain a pipe, so the field count is a
# floor, not an equality.
INVENTORY_OK=1
if [ "$DOCKER_OK" = 1 ] && [ -s "$WORK/inventory" ]; then
  if ! awk -F'|' '
    NF < 6 { exit 1 }
    $1 == "" { exit 1 }
    $2 !~ /^(created|restarting|running|removing|paused|exited|dead)$/ { exit 1 }
  ' "$WORK/inventory"; then
    INVENTORY_OK=0
    warn 'the container listing is not in the expected shape; no container will be classified'
  fi
fi

# Fields are pipe-separated, not tab-separated: tab is IFS whitespace, so `read`
# collapses runs of it and an empty label would silently shift every later field
# into the wrong variable. The last field is the one that could contain a pipe.
: >"$WORK/classified"     # name|state|verdict|project|reason
: >"$WORK/protected-projects"
while [ "$INVENTORY_OK" = 1 ] && IFS='|' read -r name state project task ports wd; do
  [ -n "${name:-}" ] || continue
  verdict=''; reason=''
  serving=0
  case "${ports:-}" in *'->'*) [ "$state" = running ] && serving=1 ;; esac

  if matches_keep_pattern "$name" || claimed_by_keep_dir "$name" "${wd:-}"; then
    verdict='keep:configured'; reason='named by the configured keep-list'
  else
    match="$(match_task_id "$name" "${project:-}" "${wd:-}" "${task:-}")"
    kind="${match%% *}"; id="${match#* }"
    if [ "$kind" = live ]; then
      verdict='keep:live-task'; reason="owned by live task $id"
    elif [ "$serving" = 1 ]; then
      verdict='keep:serving'; reason='running with a bound host port'
    elif has_stack_manifest "${wd:-}"; then
      verdict='keep:stack-claimed'; reason="claimed by the stack at $wd"
    elif [ "$kind" = 'done' ]; then
      verdict='orphan'; reason="left by finished task $id"
    elif [ "$state" = running ]; then
      verdict='keep:unattributed'; reason='running and unattributable'
    else
      verdict='reclaim:stopped'; reason='stopped and unclaimed'
    fi
  fi

  case "$verdict" in
    keep:configured|keep:live-task|keep:serving|keep:stack-claimed)
      [ -n "${project:-}" ] && printf '%s\n' "$project" >>"$WORK/protected-projects" ;;
  esac
  printf '%s|%s|%s|%s|%s\n' "$name" "$state" "$verdict" "${project:-}" "$reason" >>"$WORK/classified"
done <"$WORK/inventory"

# Protection propagates across a compose project so a live stack never loses a
# stopped member.
if [ -s "$WORK/protected-projects" ]; then
  sort -u "$WORK/protected-projects" -o "$WORK/protected-projects"
  : >"$WORK/classified.propagated"
  while IFS='|' read -r name state verdict project reason; do
    if [ "$state" != running ] && [ "${verdict#keep:}" = "$verdict" ] && [ -n "$project" ] &&
      grep -qxF "$project" "$WORK/protected-projects"; then
      verdict='keep:stack-claimed'
      reason="stopped member of the live stack $project"
    fi
    printf '%s|%s|%s|%s|%s\n' "$name" "$state" "$verdict" "$project" "$reason" >>"$WORK/classified.propagated"
  done <"$WORK/classified"
  mv "$WORK/classified.propagated" "$WORK/classified"
fi

awk -F'|' '$3 ~ /^keep:/ {print $1}' "$WORK/classified" | sort -u >"$WORK/keep-names"
awk -F'|' '$2 == "running" && $3 == "orphan" {print $1}' "$WORK/classified" | sort -u >"$WORK/kill-running"
awk -F'|' '$2 != "running" && ($3 == "orphan" || $3 == "reclaim:stopped") {print $1}' \
  "$WORK/classified" | sort -u >"$WORK/kill-stopped"
awk -F'|' '$2 == "running" {print $1}' "$WORK/classified" | sort -u >"$WORK/running-names"
awk -F'|' '$2 == "running" && $3 ~ /^keep:/ {print $1}' "$WORK/classified" | sort -u >"$WORK/keep-running"
cat "$WORK/kill-running" "$WORK/kill-stopped" | sort -u >"$WORK/kill-names"

# --- report ------------------------------------------------------------------

FREE_BEFORE="$(free_gb)"
if [ "$APPLY" = 1 ]; then
  note "firstmate housekeeping - APPLY (deleting)"
else
  note "firstmate housekeeping - DRY RUN (deleting nothing; pass --apply to reclaim)"
fi
note "free space on $DF_PATH before: ${FREE_BEFORE:-unknown} GB"
note ''

note 'containers'
if [ "$DOCKER_OK" = 0 ]; then
  note '  (docker unavailable)'
elif [ "$INVENTORY_OK" = 0 ]; then
  note '  the container listing is not in the expected shape, so nothing was classified.'
  note '  Every container is kept. Inspect the container list by hand before reclaiming.'
elif [ ! -s "$WORK/classified" ]; then
  note '  (none)'
else
  while IFS='|' read -r name state verdict _project reason; do
    case "$verdict" in
      keep:*) action='keep   ' ;;
      *) action='reclaim' ;;
    esac
    printf '  %s %-28s %s (%s)\n' "$action" "$name" "$reason" "$state"
  done <"$WORK/classified"
fi
note ''

if [ "$DOCKER_OK" = 1 ]; then
  note 'docker reclaim estimate'
  docker system df 2>/dev/null | sed 's/^/  /'
  [ "$IMAGES" = 1 ] || note '  unused images are excluded; pass --images to include them'
  note ''
fi

# --- delete-path preflight --------------------------------------------------

if [ "$APPLY" = 1 ] && [ "$DOCKER_OK" = 1 ]; then
  if [ "$INVENTORY_OK" = 0 ]; then
    refuse 'the container listing is not in the expected shape. Reclaiming from a
listing this script cannot read is how a filter that matches nothing turns into
a sweep that removes everything.'
  fi
  if [ -s "$WORK/running-names" ] && [ ! -s "$WORK/keep-running" ]; then
    refuse 'every running container ended up on the kill-list. A sweep that keeps
nothing running is the failure this script exists to prevent.'
  fi
  if [ -s "$WORK/kill-names" ]; then
    comm -12 "$WORK/kill-names" "$WORK/keep-names" >"$WORK/intersection"
    if [ -s "$WORK/intersection" ]; then
      refuse "the kill-list intersects the keep-list by name: $(tr '\n' ' ' <"$WORK/intersection")"
    fi
  fi
fi

# --- phase 1: worktrees ------------------------------------------------------

snapshot_live_worktrees() { # <output>
  local output="$1" meta id worktree
  : >"$output"
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id="$(basename "$meta" .meta)"
    worktree="$(sed -n 's/^worktree=//p' "$meta" | head -n 1)"
    [ -n "$worktree" ] && printf '%s|%s\n' "$id" "$worktree" >>"$output"
  done
}

treehouse_candidates() { # <input> <output>
  awk '
    /^Would prune [0-9]+ stale worktree/ { candidates=1; next }
    /^(Skipped|No stale worktrees|Pruned) / { candidates=0 }
    candidates && /^[[:space:]]*[0-9]+[[:space:]]+/ {
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      print
    }
  ' "$1" >"$2"
}

verify_live_worktrees() { # <snapshot>
  local snapshot="$1" id live_worktree lost=0
  while IFS='|' read -r id live_worktree; do
    [ -n "$live_worktree" ] || continue
    if [ ! -e "$live_worktree" ]; then
      warn "LIVE WORKTREE LOST: task $id records $live_worktree, which vanished during pruning"
      lost=1
    fi
  done <"$snapshot"
  return "$lost"
}

if [ "$WORKTREES" = 1 ]; then
  note 'worktrees'
  if have treehouse; then
    # --prune-orphans is deliberately never passed: an orphan is unverified.
    # Treehouse already refuses a worktree with uncommitted changes; that
    # refusal is never overridden, because a skipped worktree is unlanded work.
    if [ "$APPLY" = 1 ]; then
      if ! treehouse prune --all >"$WORK/treehouse.preflight" 2>&1; then
        refuse 'treehouse dry-run preflight failed, so live worktree exclusions could not be verified'
      fi
      treehouse_candidates "$WORK/treehouse.preflight" "$WORK/treehouse.candidates"
      snapshot_live_worktrees "$WORK/live-worktrees.before"
      while IFS='|' read -r _id live_worktree; do
        [ -n "$live_worktree" ] || continue
        if grep -qxF -- "$live_worktree" "$WORK/treehouse.candidates"; then
          refuse "treehouse proposed the live task worktree $live_worktree for pruning"
        fi
      done <"$WORK/live-worktrees.before"
      treehouse prune --all --yes >"$WORK/treehouse.out" 2>&1 || EXIT=1
      snapshot_live_worktrees "$WORK/live-worktrees.after"
      if ! verify_live_worktrees "$WORK/live-worktrees.after"; then
        sed 's/^/  /' "$WORK/treehouse.out"
        exit 1
      fi
    else
      treehouse prune --all >"$WORK/treehouse.out" 2>&1 || EXIT=1
    fi
    sed 's/^/  /' "$WORK/treehouse.out"
    if grep -qi 'uncommitted changes' "$WORK/treehouse.out"; then
      note '  ^ those carry unlanded work and were kept; report them to the captain by path'
    fi
  else
    note '  (treehouse is not installed; skipped)'
  fi
  note ''
fi

# --- phases 2-7 --------------------------------------------------------------

remove_containers() { # <list-file> <label>
  local list="$1" label="$2" name
  [ -s "$list" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Re-assert per name: the keep-list is the last word before any removal.
    if grep -qxF "$name" "$WORK/keep-names"; then
      refuse "refusing to remove $name: it is on the keep-list"
    fi
    if docker rm -f "$name" >/dev/null 2>&1; then
      note "  removed $label container $name"
    else
      warn "could not remove $label container $name"
      EXIT=1
    fi
  done <"$list"
}

prune() { # <label> <docker args...>
  local label="$1" output; shift
  note "  pruning $label"
  output="$WORK/prune-output"
  if docker "$@" >"$output" 2>&1; then
    sed 's/^/    /' "$output"
  else
    sed 's/^/    /' "$output"
    EXIT=1
  fi
}

sample_dangling_volumes() { # <output>
  local output="$1"
  if docker volume ls --filter dangling=true \
    --filter label=com.docker.volume.anonymous \
    --format '{{.Name}}' >"$output.all" 2>/dev/null; then
    sed '/^$/d' "$output.all" | sort -u >"$output"
  else
    : >"$output"
    warn 'could not list dangling anonymous volumes'
    EXIT=1
    return 1
  fi
}

container_volume_mounts() { # <container> <output>
  docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' \
    "$1" >"$2" 2>/dev/null
}

observe_protected_volume_mounts() {
  local inventory="$WORK/protected-volume-containers" name state project task ports wd mounts
  if ! docker ps -a --format "$DOCKER_FMT" >"$inventory" 2>/dev/null; then
    warn 'could not inventory protected container mounts'
    return 1
  fi
  if ! awk -F'|' '
    NF < 6 { exit 1 }
    $1 == "" { exit 1 }
    $2 !~ /^(created|restarting|running|removing|paused|exited|dead)$/ { exit 1 }
  ' "$inventory"; then
    warn 'could not parse protected container mounts'
    return 1
  fi
  while IFS='|' read -r name state project task ports wd; do
    [ -n "$name" ] || continue
    if grep -qxF "$name" "$WORK/kill-names" &&
      ! current_live_task_owns "$name" "${project:-}" "${wd:-}" "${task:-}"; then
      continue
    fi
    mounts="$WORK/protected-mounts.$name"
    if ! container_volume_mounts "$name" "$mounts"; then
      warn "could not inspect protected container $name mounts"
      return 1
    fi
    cat "$mounts" >>"$WORK/protected-volumes"
  done <"$inventory"
  sort -u "$WORK/protected-volumes" -o "$WORK/protected-volumes"
}

protected_container_not_running() {
  local inventory="$WORK/volume-containers" name state project task ports wd
  if ! docker ps -a --format "$DOCKER_FMT" >"$inventory" 2>/dev/null; then
    warn 'could not verify protected container state before volume reclamation'
    return 2
  fi
  if ! awk -F'|' '
    NF < 6 { exit 1 }
    $1 == "" { exit 1 }
    $2 !~ /^(created|restarting|running|removing|paused|exited|dead)$/ { exit 1 }
  ' "$inventory"; then
    warn 'could not parse protected container state before volume reclamation'
    return 2
  fi
  while IFS='|' read -r name state project task ports wd; do
    [ -n "${name:-}" ] || continue
    [ "$state" != running ] || continue
    if grep -qxF "$name" "$WORK/keep-names" || matches_keep_pattern "$name" ||
      claimed_by_keep_dir "$name" "${wd:-}" || has_stack_manifest "${wd:-}"; then
      printf '%s\n' "$name"
      return 0
    fi
    if current_live_task_owns "$name" "${project:-}" "${wd:-}" "${task:-}"; then
      printf '%s\n' "$name"
      return 0
    fi
  done <"$inventory"
  return 1
}

current_live_task_owns() { # <name> <project> <working-dir> <task-label>
  local hay="$1 $2 $3" label="$4" meta id
  [ -d "$STATE" ] || return 1
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id="$(basename "$meta" .meta)"
    if [ "$label" = "$id" ] || contains_token "$hay" "$id"; then
      return 0
    fi
  done
  return 1
}

stable_volume_candidates() { # <label> <output>
  local label="$1" output="$2" blocked count guard_status
  : >"$output"
  if [ "${PROTECTED_VOLUMES_CAPTURED:-0}" = 0 ]; then
    : >"$WORK/protected-volumes"
    if ! observe_protected_volume_mounts; then
      EXIT=1
      note "  skipped $label: protected container mounts could not be verified"
      return 0
    fi
    sample_dangling_volumes "$output.first" || return 1
    if ! observe_protected_volume_mounts; then
      EXIT=1
      note "  skipped $label: protected container mounts could not be verified"
      return 0
    fi
    PROTECTED_VOLUMES_CAPTURED=1
  else
    sample_dangling_volumes "$output.first" || return 1
  fi
  blocked="$(protected_container_not_running)"
  guard_status=$?
  case "$guard_status" in
    0) note "  skipped $label: protected container $blocked is not running"; return 0 ;;
    2) EXIT=1; note "  skipped $label: protected container state could not be verified"; return 0 ;;
  esac
  sleep "$VOLUME_STABILITY_SECONDS"
  sample_dangling_volumes "$output.second" || return 1
  blocked="$(protected_container_not_running)"
  guard_status=$?
  case "$guard_status" in
    0) note "  skipped $label: protected container $blocked is not running"; return 0 ;;
    2) EXIT=1; note "  skipped $label: protected container state could not be verified"; return 0 ;;
  esac
  comm -12 "$output.first" "$output.second" >"$output.common"
  comm -23 "$output.common" "$WORK/protected-volumes" >"$output"
  count="$(awk 'END { print NR + 0 }' "$output")"
  if [ "$APPLY" = 1 ]; then
    note "  reclaiming $count stable anonymous volumes from $label"
  else
    note "  would reclaim $count stable anonymous volumes from $label"
  fi
}

capture_container_volume_mounts() {
  local name volume mounts
  : >"$WORK/all-container-mounts"
  while IFS='|' read -r name _state _project _task _ports _wd; do
    [ -n "$name" ] || continue
    mounts="$WORK/model-mounts.$name"
    if ! container_volume_mounts "$name" "$mounts"; then
      warn "could not inspect container $name mounts for the reclamation model"
      EXIT=1
      return 1
    fi
    while IFS= read -r volume; do
      [ -n "$volume" ] && printf '%s|%s\n' "$name" "$volume" >>"$WORK/all-container-mounts"
    done <"$mounts"
  done <"$WORK/inventory"
}

capture_anonymous_volumes() {
  if ! docker volume ls --filter label=com.docker.volume.anonymous \
    --format '{{.Name}}' >"$WORK/anonymous-volumes.raw" 2>/dev/null; then
    warn 'could not establish anonymous volume metadata'
    EXIT=1
    return 1
  fi
  sed '/^$/d' "$WORK/anonymous-volumes.raw" | sort -u >"$WORK/anonymous-volumes"
}

model_volume_candidates() { # <stable-input> <output>
  local stable="$1" output="$2" volume ref shared
  : >"$output.added"
  awk -F'|' '{ print $2 }' "$WORK/all-container-mounts" | sort -u >"$output.mounted"
  while IFS= read -r volume; do
    [ -n "$volume" ] || continue
    shared=0
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      if ! grep -qxF "$ref" "$WORK/model-removed-containers"; then
        shared=1
        break
      fi
    done < <(awk -F'|' -v volume="$volume" '$2 == volume { print $1 }' "$WORK/all-container-mounts")
    [ "$shared" = 0 ] || continue
    grep -qxF "$volume" "$WORK/anonymous-volumes" || continue
    grep -qxF "$volume" "$WORK/protected-volumes" && continue
    printf '%s\n' "$volume" >>"$output.added"
  done <"$output.mounted"
  cat "$stable" "$output.added" | sort -u >"$output.all"
  comm -23 "$output.all" "$WORK/model-reported-volumes" >"$output"
}

plan_remove_containers() { # <list-file> <label>
  local list="$1" label="$2"
  if [ "$APPLY" = 1 ]; then
    remove_containers "$list" "$label"
  else
    cat "$list" >>"$WORK/model-removed-containers"
    sort -u "$WORK/model-removed-containers" -o "$WORK/model-removed-containers"
  fi
}

plan_volume_pass() { # <label> <suffix>
  local label="$1" suffix="$2" stable list volume count
  stable="$WORK/volumes.$suffix.stable"
  list="$WORK/volumes.$suffix"
  stable_volume_candidates "$label" "$stable"
  if [ "$APPLY" = 0 ]; then
    model_volume_candidates "$stable" "$list"
    count="$(awk 'END { print NR + 0 }' "$list")"
    note "  would reclaim $count anonymous volumes from $label:"
    if [ -s "$list" ]; then sed 's/^/    /' "$list"; else note '    (none)'; fi
    note '  this modelled set is an upper bound subject to the same apply-time stability check'
    cat "$list" >>"$WORK/model-reported-volumes"
    sort -u "$WORK/model-reported-volumes" -o "$WORK/model-reported-volumes"
    return 0
  fi
  list="$stable"
  while IFS= read -r volume; do
    [ -n "$volume" ] || continue
    if ! docker volume rm "$volume" >/dev/null 2>&1; then
      warn 'could not remove a stable anonymous volume'
      EXIT=1
    fi
  done <"$list"
}

plan_prune() { # <label> <docker args...>
  local label="$1"; shift
  if [ "$APPLY" = 1 ]; then
    prune "$label" "$@"
  else
    note "  would prune $label"
  fi
}

run_reclamation_plan() {
  plan_remove_containers "$WORK/kill-stopped" stopped
  plan_volume_pass 'first volume pass after stopped containers' first
  plan_prune 'build cache' builder prune -f
  plan_remove_containers "$WORK/kill-running" orphaned
  plan_volume_pass 'second volume pass after orphan removal' second
  if [ "$IMAGES" = 1 ]; then
    plan_prune 'unused images' image prune -a -f
  fi
}

if [ "$DOCKER_OK" = 1 ]; then
  note "$([ "$APPLY" = 1 ] && printf reclaiming || printf 'reclamation plan')"
  if [ "$INVENTORY_OK" = 1 ]; then
    : >"$WORK/model-removed-containers"
    : >"$WORK/model-reported-volumes"
    if capture_container_volume_mounts && capture_anonymous_volumes; then
      run_reclamation_plan
    else
      note '  skipped dangling volumes: protected container state could not be verified'
    fi
  fi
  note ''
fi

if [ "$APPLY" = 0 ]; then
  note 'nothing was deleted. Re-run with --apply to reclaim the above.'
  exit "$EXIT"
fi

# --- verification ------------------------------------------------------------

note 'verification'
if [ "$DOCKER_OK" = 1 ]; then
  docker ps --format '{{.Names}}' 2>/dev/null | sort -u >"$WORK/running-after"
  lost=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! grep -qxF "$name" "$WORK/running-after"; then
      note "  FAILED: protected container $name is no longer running"
      lost=1
      EXIT=1
    fi
  done <"$WORK/keep-running"
  [ "$lost" = 0 ] && note '  every protected container is still running'
else
  note '  (docker unavailable)'
fi
FREE_AFTER="$(free_gb)"
note "  free space on $DF_PATH: ${FREE_BEFORE:-unknown} GB before, ${FREE_AFTER:-unknown} GB after"

exit "$EXIT"
