# fm-progress.jq - single owner of fleet progress ladder derivation and bar rendering.
#
# Loaded by callers with:
#   jq -L "$SCRIPT_DIR" 'include "fm-progress"; ...'
#
# There is exactly one implementation of both the ladder and the bar.
# Renderers call fm_progress_bar on a progress object the snapshot already
# derived; they never re-derive stages themselves.
#
# Progress object shape:
#   {ladder, stages[], stage, reached, total, fraction, flag, evidence}
# where fraction is null when total is 0, and flag is null unless the task is in
# an exceptional state.
#
# Derivation is MONOTONE HIGH-WATER, never current state: `reached` is the
# highest ladder index whose evidence is present, scanning every milestone. A
# transient state cannot pull the bar backwards, so a task that recorded a PR and
# then hit a decision hold stays at the PR stage and raises `flag` instead of
# dropping to `working`. Every evidence signal below is durable for that reason.

# Ladder selection, by task kind and delivery mode.
# An empty or unknown mode maps to ship-no-mistakes because that is
# fm-brief.sh's default delivery mode.
def fm_progress_ladder($t):
  ($t.kind // "ship") as $kind
  | ($t.mode // "") as $mode
  | if $kind == "secondmate" then "none"
    elif $kind == "scout" then "scout"
    elif $mode == "direct-PR" then "ship-direct-pr"
    elif $mode == "local-only" then "ship-local-only"
    else "ship-no-mistakes"
    end;

# A persistent secondmate has no finish line, so ladder "none" carries no stages
# and renders no bar.
def fm_progress_stages($ladder):
  if $ladder == "ship-no-mistakes" then
    ["dispatched", "working", "validating", "pr-open", "checks-green", "merged"]
  elif $ladder == "ship-direct-pr" then
    ["dispatched", "working", "pr-open", "merged"]
  elif $ladder == "ship-local-only" then
    ["dispatched", "working", "ready", "merged"]
  elif $ladder == "scout" then
    ["dispatched", "working", "report"]
  elif $ladder == "backlog" then
    ["under-way", "landed"]
  else []
  end;

# Every `done:` line the append-only status log ever recorded. These are
# permanent: unlike current_state, which is a live read that decays once a run
# stops being attributable, an appended line is never retracted. Terminal
# milestones key off this so the bar cannot drop backwards between snapshots.
#
# Only lines the snapshot already verified to carry the `done` status verb are
# admitted. hints.last_event_text is deliberately NOT folded in: it is the raw
# last line whatever its verb, so a `working: rebased onto merged #76` style line
# would satisfy a terminal milestone by prose alone.
def fm_progress_done_events($t):
  ($t.hints.done_events // [])
  | map(select(type == "string" and . != ""));

# Durable evidence for one stage of a live task.
def fm_progress_task_reached($t; $stage):
  if $stage == "dispatched" then
    # The task object exists only because state/<id>.meta exists.
    true
  elif $stage == "working" then
    ($t.paths.status_log.present == true)
    or (($t.current_state.state // "unknown") != "unknown")
  elif $stage == "validating" then
    # current_state.source == "run-step" would be the natural live signal here,
    # and it is exactly the signal the monotone rule forbids: fm-crew-state.sh
    # falls back run-step -> pane -> status-log the moment a run stops being
    # attributable, so an unchanged task would drop 3/6 back to 2/6 in the whole
    # window before a PR exists. A recorded PR is the only durable proof that
    # validation happened, so this rung shares pr-open's evidence rather than
    # holding a stage up on a read that decays. An honest ladder that skips a
    # rung beats a bar that moves backwards.
    $t.pr.url != null
  elif $stage == "pr-open" then
    $t.pr.url != null
  elif $stage == "checks-green" then
    # A no-mistakes worker reports `done: PR <url> checks green` (fm-brief.sh),
    # so the wording itself is the evidence. The distinction is load-bearing: on
    # direct-PR a `done:` line only means the PR was opened, never that checks
    # passed, and the snapshot makes no network calls. That is exactly why
    # checks-green is absent from the ship-direct-pr ladder.
    ($t.pr.url != null)
    and (fm_progress_done_events($t) | any(test("checks green"; "i")))
  elif $stage == "ready" then
    # A local-only worker reports `done: ready in branch <branch>` (fm-brief.sh).
    fm_progress_done_events($t) | any(test("ready in branch"; "i"))
  elif $stage == "report" then
    $t.paths.report.present == true
  elif $stage == "merged" then
    # Never reachable from a live task: a merged ship task is torn down and its
    # state/<id>.meta is gone, so no task object can survive to report it. A live
    # ship task therefore tops out one stage short, which is the honest reading -
    # "PR up, waiting to land".
    false
  else false
  end;

def fm_progress_evidence($stage):
  if $stage == "dispatched" then "metadata recorded"
  elif $stage == "working" then "worker observed"
  elif $stage == "validating" then "PR recorded"
  elif $stage == "pr-open" then "PR recorded"
  elif $stage == "checks-green" then "validation reported checks green"
  elif $stage == "ready" then "branch reported ready"
  elif $stage == "report" then "report written"
  elif $stage == "merged" then "merge recorded"
  else "no milestone reached"
  end;

# The top reachable stage of a ship ladder is the one just below the unreachable
# `merged`: checks-green on ship-no-mistakes, pr-open on ship-direct-pr, ready on
# ship-local-only. Reaching it means the work is finished and sitting on the
# captain. It is flagged because otherwise "done, waiting on you" renders as a
# bare bar indistinguishable from "still grinding". A scout tops out at its
# report, which is the deliverable rather than something awaiting a merge, so
# only ship ladders qualify.
def fm_progress_awaiting_merge($ladder; $reached; $total):
  ($ladder | startswith("ship-")) and $total > 0 and $reached == ($total - 1);

# Exceptional state, first match wins. A flag never changes `reached`.
def fm_progress_flag($t; $ladder; $reached; $total):
  if ($t.current_state.state // "") == "failed" then "failed"
  elif $t.hints.blocked_event == true then "blocked"
  # Both decision arms are needed and neither subsumes the other:
  # pending_decision is folded from status-log events the worker appended, while
  # `parked` is what fm-crew-state.sh reports for a no-mistakes run sitting at an
  # awaiting_approval or fix_review gate. A run parked at a gate where the worker
  # never appended a needs-decision: line is exactly the "stopped, waiting on a
  # decision" case that must not render as a bare bar.
  elif ($t.hints.pending_decision == true)
       or (($t.current_state.state // "") == "parked") then "decision"
  elif fm_progress_awaiting_merge($ladder; $reached; $total) then "awaiting-merge"
  elif ($t.current_state.state // "") == "paused" then "paused"
  else null
  end;

def fm_progress_fraction($reached; $total):
  if $total == 0 then null
  else ((($reached / $total) * 100) | round) / 100
  end;

def fm_progress_of_task($t):
  fm_progress_ladder($t) as $ladder
  | fm_progress_stages($ladder) as $stages
  | ($stages | length) as $total
  | ([range(0; $total) | select(fm_progress_task_reached($t; $stages[.]))] | last) as $top
  | (if $top == null then 0 else $top + 1 end) as $reached
  | (if $top == null then null else $stages[$top] end) as $stage
  | {ladder: $ladder,
     stages: $stages,
     stage: $stage,
     reached: $reached,
     total: $total,
     fraction: fm_progress_fraction($reached; $total),
     flag: fm_progress_flag($t; $ladder; $reached; $total),
     evidence: (if $stage == null then
                  (if $ladder == "none" then "persistent secondmate, no ladder"
                   else "no milestone reached" end)
                else fm_progress_evidence($stage) end)};

# Backlog records carry no worker telemetry, only their section, so the ladder is
# the two durable milestones a backlog row can prove on its own.
def fm_progress_of_backlog($r):
  fm_progress_stages("backlog") as $stages
  | (if ($r.state // "") == "queued" then {reached: 0, evidence: "queued"}
     elif ($r.state // "") == "in_flight" then {reached: 1, evidence: "under way"}
     elif ($r.state // "") == "done" then {reached: 2, evidence: "landed"}
     else {reached: 0, evidence: "unknown backlog state"}
     end) as $m
  | ($stages | length) as $total
  | {ladder: "backlog",
     stages: $stages,
     stage: (if $m.reached == 0 then null else $stages[$m.reached - 1] end),
     reached: $m.reached,
     total: $total,
     fraction: fm_progress_fraction($m.reached; $total),
     flag: null,
     evidence: $m.evidence};

# ASCII only. Block-drawing and braille glyphs are deliberately avoided: this
# repo has already been bitten by locale- and font-sensitive glyph matching, and
# these strings land in agent-parsed output.
def fm_progress_bar($p; $width):
  if $p == null or ($p | type) != "object" then "-"
  elif ($p.total // 0) == 0 or ($p.ladder // "none") == "none" then "-"
  else
    ($p.fraction // 0) as $f
    | (($f * $width) | round) as $raw
    | (if $raw < 0 then 0 elif $raw > $width then $width else $raw end) as $fill
    | "["
      + (("#" * $fill) // "")
      + (("." * ($width - $fill)) // "")
      + "] "
      + ((($f * 100) | round) | tostring)
      + "%"
      + (if $p.flag == null then "" else " !" + $p.flag end)
  end;
