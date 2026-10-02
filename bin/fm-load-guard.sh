#!/usr/bin/env bash
# fm-load-guard.sh - wake firstmate when this machine runs short of memory or
# CPU, so the fleet sheds load before the captain's machine is exhausted.
#
# Usage:
#   fm-load-guard.sh [check]
#   fm-load-guard.sh status
#   fm-load-guard.sh arm
#   fm-load-guard.sh disarm
#   fm-load-guard.sh --help
#
# `check` prints exactly one line when a threshold is crossed and prints nothing
# otherwise, so it composes with the watcher state-check contract: the watcher
# turns that line into a `check:` wake. `status` always prints the reading as
# key=value lines and never writes anything; bin/fm-spawn.sh reads its verdict
# before every launch. `arm` writes state/load-guard.check.sh and binds its
# bytes with fm-check-register.sh; bin/fm-bootstrap.sh runs it on every locked
# session start, so every home, including every secondmate home, converges to
# armed without anyone remembering to do it. `disarm` retires the shim and its
# trust binding through fm-check-unregister.sh and removes the episode record.
#
# Measurement is direct and portable, never inferred from a load average:
#
#   macOS  memory  `memory_pressure` "System-wide memory free percentage"
#          CPU     `iostat -c 2 -w <sample>`, the idle column of the second
#                  (measured, not since-boot) sample
#   Linux  memory  MemAvailable / MemTotal from /proc/meminfo
#          CPU     idle + iowait share of two /proc/stat samples <sample> apart
#
# A metric that cannot be measured - an unknown platform, a missing tool, a
# timed-out or unparseable probe - is unknown, and an unknown metric never
# alarms and never refuses a spawn. The whole measurement is bounded well under
# the watcher's per-check FM_CHECK_TIMEOUT (default 30): each probe gets
# FM_LOAD_GUARD_SAMPLE_SECS (default 1, valid 1..5) plus 4 seconds.
#
# Thresholds come from the optional config/load-guard (docs/configuration.md
# "Load guard" owns the format). Defaults: alert when memory free is below 25%
# or CPU idle is below 10%; bin/fm-spawn.sh refuses a new launch when memory
# free is below 15%. A line `off` in that file, or FM_LOAD_GUARD=off in the
# environment, disables the check, the spawn gate, and arming. A malformed file
# keeps the defaults and is reported once, never silently.
#
# Re-alert dedupe: state/.load-guard records the current high-load episode -
# when it started, when it last alerted, and which metrics are in it. The check
# alerts when an episode starts, when a metric newly joins it, and then at most
# once per remind_secs (default 1800, 0 = episode start only) while it persists,
# and only on a poll that measures a crossed metric. A metric joins the episode
# the moment it is measured crossed and leaves only after it has been measured
# clear for clear_secs (default 900, 0 = the first clear poll), so a reading
# that hovers around its threshold stays one episode instead of ending and
# restarting it on alternate polls. A metric that is unknown on a poll keeps its
# recorded state rather than leaving or rejoining the episode. The episode ends
# when no metric is left in it.
#
# Test seams, never needed in a live home: FM_LOAD_GUARD_PLATFORM forces the
# parser (darwin|linux), FM_LOAD_GUARD_PROC_DIR replaces /proc, and
# FM_LOAD_GUARD_PROC_STAT_LATER names the file read as the second /proc/stat
# sample. FM_LOAD_GUARD_NOW pins the record clock.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/load-guard"
RECORD="$STATE/.load-guard"
CHECK_ID=load-guard
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
RECORD_SCHEMA=fm-load-guard-v1

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-load-guard.sh [check]   one wake line when memory or CPU crosses its threshold (silent otherwise)
  fm-load-guard.sh status    print the current reading and verdict as key=value lines
  fm-load-guard.sh arm       write and register state/load-guard.check.sh (disarms when config/load-guard is off)
  fm-load-guard.sh disarm    remove the check shim, its trust binding, and the episode record
  fm-load-guard.sh --help    print this help

Thresholds and the off switch are read from config/load-guard (local, optional).
See docs/configuration.md "Load guard" for the format.
EOF
}

die_usage() {
  printf 'fm-load-guard: %s\n' "$1" >&2
  usage >&2
  exit 2
}

DEFAULT_MEMORY_ALERT=25
DEFAULT_CPU_ALERT=10
DEFAULT_SPAWN_FLOOR=15
DEFAULT_REMIND=1800
DEFAULT_CLEAR=900

SAMPLE_SECS=${FM_LOAD_GUARD_SAMPLE_SECS:-1}
case "$SAMPLE_SECS" in
  [1-5]) ;;
  *) SAMPLE_SECS=1 ;;
esac
PROBE_SECS=$((SAMPLE_SECS + 4))

now_epoch() {
  case "${FM_LOAD_GUARD_NOW:-}" in
    '' | *[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_LOAD_GUARD_NOW" ;;
  esac
}

# --- configuration ----------------------------------------------------------

GUARD_OFF=0
CONFIG_ERROR=
MEMORY_ALERT=$DEFAULT_MEMORY_ALERT
CPU_ALERT=$DEFAULT_CPU_ALERT
SPAWN_FLOOR=$DEFAULT_SPAWN_FLOOR
REMIND=$DEFAULT_REMIND
CLEAR=$DEFAULT_CLEAR

# pct_in_range <value> <min> <max>: a plain whole number inside the range.
pct_in_range() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 5 ] || return 1
  [ "$((10#$1))" -ge "$2" ] && [ "$((10#$1))" -le "$3" ]
}

# A malformed file keeps every default rather than applying half of it, and the
# problem is reported instead of guessed around. `off` is honored even then,
# because it is the one unambiguous thing the file can say.
config_load() {
  local line key value min mem=$DEFAULT_MEMORY_ALERT cpu=$DEFAULT_CPU_ALERT
  local floor=$DEFAULT_SPAWN_FLOOR remind=$DEFAULT_REMIND clear=$DEFAULT_CLEAR error=
  [ "${FM_LOAD_GUARD:-}" != off ] || GUARD_OFF=1
  [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] || return 0
  if [ ! -f "$CONFIG_FILE" ] || [ ! -r "$CONFIG_FILE" ]; then
    CONFIG_ERROR="config/load-guard is not a readable regular file"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d ' \t\r')
    [ -n "$line" ] || continue
    if [ "$line" = off ]; then
      GUARD_OFF=1
      continue
    fi
    key=${line%%=*}
    value=${line#*=}
    if [ "$key" = "$line" ]; then
      [ -n "$error" ] || error="unrecognized line '$line'"
      continue
    fi
    case "$key" in
      memory_free_alert_pct | cpu_idle_alert_pct | memory_free_spawn_floor_pct)
        if [ "$key" = memory_free_spawn_floor_pct ]; then min=0; else min=1; fi
        if ! pct_in_range "$value" "$min" 99; then
          [ -n "$error" ] || error="$key must be $min..99"
          continue
        fi
        case "$key" in
          memory_free_alert_pct) mem=$((10#$value)) ;;
          cpu_idle_alert_pct) cpu=$((10#$value)) ;;
          *) floor=$((10#$value)) ;;
        esac
        ;;
      remind_secs | clear_secs)
        if [ "$value" != 0 ] && ! pct_in_range "$value" 60 86400; then
          [ -n "$error" ] || error="$key must be 0 or 60..86400"
          continue
        fi
        case "$key" in
          remind_secs) remind=$((10#$value)) ;;
          *) clear=$((10#$value)) ;;
        esac
        ;;
      *)
        [ -n "$error" ] || error="unrecognized key '$key'"
        ;;
    esac
  done < "$CONFIG_FILE"
  if [ -z "$error" ] && [ "$floor" -gt "$mem" ]; then
    error="memory_free_spawn_floor_pct ($floor) is above memory_free_alert_pct ($mem)"
  fi
  if [ -n "$error" ]; then
    CONFIG_ERROR="config/load-guard: $error"
    return 0
  fi
  MEMORY_ALERT=$mem
  CPU_ALERT=$cpu
  SPAWN_FLOOR=$floor
  REMIND=$remind
  CLEAR=$clear
}

# --- measurement ------------------------------------------------------------

platform() {
  case "${FM_LOAD_GUARD_PLATFORM:-$(uname -s 2>/dev/null)}" in
    Darwin | darwin) printf 'darwin\n' ;;
    Linux | linux) printf 'linux\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# valid_pct <value>: prints the value as a whole number 0..100, or fails.
valid_pct() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 3 ] && [ "$((10#$1))" -le 100 ] || return 1
  printf '%s\n' "$((10#$1))"
}

memory_darwin() {
  local out
  command -v memory_pressure >/dev/null 2>&1 || return 1
  out=$(fm_run_timed "$PROBE_SECS" memory_pressure 2>/dev/null) || return 1
  valid_pct "$(printf '%s\n' "$out" | awk -F': *' '/free percentage/ { v = $2; sub(/%.*/, "", v); print v; exit }')"
}

# The idle column is located by its header, not by position, because iostat
# prints one block of columns per disk before the cpu block. The last data row is
# the measured interval; the first is the since-boot average.
cpu_darwin() {
  local out
  command -v iostat >/dev/null 2>&1 || return 1
  out=$(fm_run_timed "$PROBE_SECS" iostat -c 2 -w "$SAMPLE_SECS" 2>/dev/null) || return 1
  valid_pct "$(printf '%s\n' "$out" | awk '
    col == 0 { for (i = 1; i <= NF; i++) if ($i == "id") { col = i; width = NF } next }
    NF == width && $col ~ /^[0-9]+(\.[0-9]+)?$/ { v = $col }
    END { if (v != "") printf "%d\n", v + 0.5 }
  ')"
}

memory_linux() {
  local proc=${FM_LOAD_GUARD_PROC_DIR:-/proc}
  [ -r "$proc/meminfo" ] || return 1
  valid_pct "$(awk '
    $1 == "MemTotal:" { total = $2 }
    $1 == "MemAvailable:" { avail = $2 }
    END { if (total > 0 && avail != "") printf "%d\n", avail * 100 / total }
  ' "$proc/meminfo")"
}

# Prints "<idle+iowait> <total>" from the aggregate cpu line.
proc_stat_sample() {
  awk '$1 == "cpu" { t = 0; for (i = 2; i <= 9 && i <= NF; i++) t += $i; printf "%.0f %.0f\n", $5 + $6, t; exit }' "$1" 2>/dev/null
}

cpu_linux() {
  local proc=${FM_LOAD_GUARD_PROC_DIR:-/proc} later first second
  later=${FM_LOAD_GUARD_PROC_STAT_LATER:-$proc/stat}
  [ -r "$proc/stat" ] || return 1
  first=$(proc_stat_sample "$proc/stat")
  [ -n "$first" ] || return 1
  sleep "$SAMPLE_SECS"
  second=$(proc_stat_sample "$later")
  [ -n "$second" ] || return 1
  valid_pct "$(printf '%s %s\n' "$first" "$second" | awk '
    { di = $3 - $1; dt = $4 - $2; if (dt > 0 && di >= 0 && di <= dt) printf "%d\n", di * 100 / dt }
  ')"
}

MEMORY_FREE=
CPU_IDLE=

measure() {
  case "$(platform)" in
    darwin)
      MEMORY_FREE=$(memory_darwin) || MEMORY_FREE=
      CPU_IDLE=$(cpu_darwin) || CPU_IDLE=
      ;;
    linux)
      MEMORY_FREE=$(memory_linux) || MEMORY_FREE=
      CPU_IDLE=$(cpu_linux) || CPU_IDLE=
      ;;
    *)
      MEMORY_FREE=
      CPU_IDLE=
      ;;
  esac
}

memory_crossed() { [ -n "$MEMORY_FREE" ] && [ "$MEMORY_FREE" -lt "$MEMORY_ALERT" ]; }
cpu_crossed() { [ -n "$CPU_IDLE" ] && [ "$CPU_IDLE" -lt "$CPU_ALERT" ]; }
below_spawn_floor() { [ -n "$MEMORY_FREE" ] && [ "$MEMORY_FREE" -lt "$SPAWN_FLOOR" ]; }

# The human summary of the current reading, shared by the wake line and status.
reading_summary() {
  local mem cpu
  if [ -z "$MEMORY_FREE" ]; then
    mem="memory unmeasured"
  elif memory_crossed; then
    mem="memory ${MEMORY_FREE}% free (alert below ${MEMORY_ALERT}%)"
  else
    mem="memory ${MEMORY_FREE}% free"
  fi
  if [ -z "$CPU_IDLE" ]; then
    cpu="CPU unmeasured"
  elif cpu_crossed; then
    cpu="CPU ${CPU_IDLE}% idle (alert below ${CPU_ALERT}%)"
  else
    cpu="CPU ${CPU_IDLE}% idle"
  fi
  printf '%s, %s\n' "$mem" "$cpu"
}

# --- episode record ---------------------------------------------------------

REC_SINCE=
REC_LAST=
REC_CROSSED=
REC_MEMORY_CLEAR_SINCE=
REC_CPU_CLEAR_SINCE=
REC_CONFIG_ERROR=

record_read() {
  local key value
  REC_SINCE=''
  REC_LAST=''
  REC_CROSSED=''
  REC_MEMORY_CLEAR_SINCE=''
  REC_CPU_CLEAR_SINCE=''
  REC_CONFIG_ERROR=''
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  [ "$(head -n 1 "$RECORD" 2>/dev/null)" = "schema=$RECORD_SCHEMA" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      since) case "$value" in '' | *[!0-9]*) ;; *) REC_SINCE=$value ;; esac ;;
      last) case "$value" in '' | *[!0-9]*) ;; *) REC_LAST=$value ;; esac ;;
      crossed) case "$value" in memory | cpu | memory,cpu) REC_CROSSED=$value ;; esac ;;
      memory_clear_since) case "$value" in '' | *[!0-9]*) ;; *) REC_MEMORY_CLEAR_SINCE=$value ;; esac ;;
      cpu_clear_since) case "$value" in '' | *[!0-9]*) ;; *) REC_CPU_CLEAR_SINCE=$value ;; esac ;;
      config_error) REC_CONFIG_ERROR=$value ;;
    esac
  done < "$RECORD"
  if [ -z "$REC_SINCE" ] || [ -z "$REC_LAST" ] || [ -z "$REC_CROSSED" ]; then
    REC_SINCE=''
    REC_LAST=''
    REC_CROSSED=''
    REC_MEMORY_CLEAR_SINCE=''
    REC_CPU_CLEAR_SINCE=''
  fi
}

record_write() {  # <since> <last> <crossed> <config-error> <memory-clear-since> <cpu-clear-since>
  local tmp
  if [ -z "$1" ] && [ -z "$4" ]; then
    rm -f -- "$RECORD"
    return 0
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  [ ! -L "$RECORD" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-load-guard.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'schema=%s\n' "$RECORD_SCHEMA"
    if [ -n "$1" ]; then
      printf 'since=%s\nlast=%s\ncrossed=%s\n' "$1" "$2" "$3"
      [ -z "$5" ] || printf 'memory_clear_since=%s\n' "$5"
      [ -z "$6" ] || printf 'cpu_clear_since=%s\n' "$6"
    fi
    [ -z "$4" ] || printf 'config_error=%s\n' "$4"
  } > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

has_metric() {  # <set> <metric>
  case ",$1," in
    *",$2,"*) return 0 ;;
  esac
  return 1
}

# episode_metric <metric> <reading> <alert-threshold> <recorded-clear-since> <now>
# decides whether <metric> is in the episode after this poll. It joins the
# moment it is measured crossed, and leaves only once it has been measured clear
# for CLEAR seconds, so a reading hovering around its threshold neither ends the
# episode nor rejoins it as news. A metric that could not be measured keeps the
# state the record gave it, so one failed probe changes nothing.
# Sets EP_HELD (1 = in the episode) and EP_CLEAR_SINCE (when a held metric was
# first measured clear, empty while it is crossed).
EP_HELD=0
EP_CLEAR_SINCE=

episode_metric() {
  local metric=$1 reading=$2 threshold=$3 clear_since=$4 now=$5
  EP_HELD=0
  EP_CLEAR_SINCE=''
  if [ -n "$reading" ] && [ "$reading" -lt "$threshold" ]; then
    EP_HELD=1
    return 0
  fi
  has_metric "$REC_CROSSED" "$metric" || return 0
  if [ -z "$reading" ]; then
    EP_HELD=1
    EP_CLEAR_SINCE=$clear_since
    return 0
  fi
  [ -n "$clear_since" ] && [ "$clear_since" -le "$now" ] || clear_since=$now
  if [ "$((now - clear_since))" -lt "$CLEAR" ]; then
    EP_HELD=1
    EP_CLEAR_SINCE=$clear_since
  fi
  return 0
}

duration_phrase() {
  local secs=$1
  if [ "$secs" -ge 3600 ]; then
    printf '%dh%02dm\n' "$((secs / 3600))" "$(((secs % 3600) / 60))"
  else
    printf '%dm\n' "$((secs / 60))"
  fi
}

# --- actions ----------------------------------------------------------------

action_check() {
  local now crossed='' alert='' line='' since last memory_clear_since cpu_clear_since
  config_load
  if [ "$GUARD_OFF" -eq 1 ]; then
    rm -f -- "$RECORD"
    return 0
  fi
  record_read
  measure
  now=$(now_epoch)

  episode_metric memory "$MEMORY_FREE" "$MEMORY_ALERT" "$REC_MEMORY_CLEAR_SINCE" "$now"
  [ "$EP_HELD" -eq 0 ] || crossed=memory
  memory_clear_since=$EP_CLEAR_SINCE
  episode_metric cpu "$CPU_IDLE" "$CPU_ALERT" "$REC_CPU_CLEAR_SINCE" "$now"
  [ "$EP_HELD" -eq 0 ] || crossed=${crossed:+$crossed,}cpu
  cpu_clear_since=$EP_CLEAR_SINCE

  # Never alarm on a carried or held state alone: something measured now must
  # be crossed. The reminder clock moves only when a line is actually emitted,
  # so a reminder that comes due on such a poll fires on the next crossed one.
  since=$REC_SINCE
  last=$REC_LAST
  if memory_crossed || cpu_crossed; then
    if [ -z "$REC_CROSSED" ]; then
      since=$now last=$now
      alert="high load"
    elif { memory_crossed && ! has_metric "$REC_CROSSED" memory; } \
      || { cpu_crossed && ! has_metric "$REC_CROSSED" cpu; }; then
      last=$now
      alert="load worsened, high since $(duration_phrase "$((now - since))") ago"
    elif [ "$REMIND" -gt 0 ] && [ "$((now - last))" -ge "$REMIND" ]; then
      last=$now
      alert="still high after $(duration_phrase "$((now - since))")"
    fi
  fi

  if [ -n "$alert" ]; then
    line="load-guard: $(reading_summary) - $alert"
    if below_spawn_floor; then
      line="$line; new spawns refused below ${SPAWN_FLOOR}% free"
    fi
  fi
  if [ -n "$CONFIG_ERROR" ] && [ "$CONFIG_ERROR" != "$REC_CONFIG_ERROR" ]; then
    if [ -n "$line" ]; then
      line="$line; $CONFIG_ERROR (using defaults)"
    else
      line="load-guard: $CONFIG_ERROR (using defaults)"
    fi
  fi
  [ -z "$line" ] || printf '%s\n' "$line"
  record_write "${crossed:+$since}" "${crossed:+$last}" "$crossed" "$CONFIG_ERROR" \
    "$memory_clear_since" "$cpu_clear_since" || true
  return 0
}

action_status() {
  local verdict
  config_load
  if [ "$GUARD_OFF" -eq 1 ]; then
    printf 'verdict=off\n'
    return 0
  fi
  measure
  if [ -z "$MEMORY_FREE" ] && [ -z "$CPU_IDLE" ]; then
    verdict=unknown
  elif below_spawn_floor; then
    verdict=refuse
  elif memory_crossed || cpu_crossed; then
    verdict=alert
  else
    verdict=ok
  fi
  printf 'verdict=%s\n' "$verdict"
  printf 'memory_free_pct=%s\n' "${MEMORY_FREE:-unknown}"
  printf 'cpu_idle_pct=%s\n' "${CPU_IDLE:-unknown}"
  printf 'memory_free_alert_pct=%s\n' "$MEMORY_ALERT"
  printf 'cpu_idle_alert_pct=%s\n' "$CPU_ALERT"
  printf 'memory_free_spawn_floor_pct=%s\n' "$SPAWN_FLOOR"
  printf 'summary=%s\n' "$(reading_summary)"
  [ -z "$CONFIG_ERROR" ] || printf 'config_error=%s (using defaults)\n' "$CONFIG_ERROR"
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would check a different
# home's configuration and record.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-load-guard.sh - memory and CPU load guard shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-load-guard.sh") check"
}

# Write the shim the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-load-guard.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim already in place, so a failed arm puts back what a
# working home was using rather than leaving it unarmed.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-load-guard.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about an unauthenticated state check. So after a failed or
# interrupted arm the home never holds a shim without a matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-load-guard: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ] \
    || [ -e "$STATE/$CHECK_ID.check-trust" ] || [ -L "$STATE/$CHECK_ID.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || {
      printf 'fm-load-guard: could not unregister state/%s.check.sh\n' "$CHECK_ID" >&2
      return 1
    }
  fi
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

# Idempotent: a home already armed with these exact bytes and a valid binding
# is left untouched, so running this on every session start writes nothing.
action_arm() {
  local want home
  config_load
  if [ "$GUARD_OFF" -eq 1 ]; then
    action_disarm >/dev/null || return 1
    printf 'disarmed: state/%s.check.sh (load guard is off)\n' "$CHECK_ID"
    return 0
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-load-guard: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-load-guard: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-load-guard: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-load-guard: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  status) action_status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h | --help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
