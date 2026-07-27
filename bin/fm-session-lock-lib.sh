#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^omp$'

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args script
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    case "$comm" in
      *node*|*python*)
        # Bare interpreter (e.g. node): match the harness by the script's
        # basename, not by scanning prompt arguments (which could false-match a
        # prompt word) and not against the whole args line (which anchored short
        # names like ^pi$ / ^omp$ can never match).
        script=${args#* }; script=${script%% *}
        [ -n "$script" ] && printf '%s' "$(basename "$script")" | grep -qE "$FM_HARNESS_RE" \
          && { echo "$pid"; return 0; }
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args script
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  # Match the command name on its own so anchored short names (^pi$, ^omp$) work;
  # only a bare interpreter falls back to matching the harness name in its args.
  if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      script=${args#* }; script=${script%% *}
      [ -n "$script" ] && printf '%s' "$(basename "$script")" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
