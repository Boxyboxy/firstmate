---
name: bearings
description: >-
  Generate a decision-ready "pick up where I left off" digest from firstmate's live fleet state, for the whole fleet or only the projects the captain names.
  Use when the captain invokes /bearings or asks in plain language for a bearings report, morning brief, status report, catch-up, "where did I leave off", "what's in the works", "where are we on <project>", or what is waiting on their decision.
  Plain /bearings is chat-only by default, /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact, and /bearings lavish additionally builds and arms the interactive fleet board; live PR enrichment remains opt-in and composes with the other modes.
  Also load this skill's board-wake handling when a procevent lavish wake's source id matches the canonical source id of the stable bearings board path.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset, and can settle what only they can settle without opening anything else.
One contract serves every scope: one project, several projects, or the whole fleet.
Plain `/bearings` returns only the chat digest: the position lead-in and the four sections in the chat-response contract below.
Only `/bearings file` writes the dated markdown report artifact and then returns the same chat digest linked to that report.
Only `/bearings lavish` builds the interactive fleet board beside that digest, through `bin/fm-bearings-board.sh` (its header owns every board mechanic and the fm-bearings-board.v1 payload contract).
A digest/build invocation is operationally read-only apart from those explicit per-mode artifacts: the dated report in file mode, and in lavish mode the board file plus the answer binding and source registration that `bin/fm-bearings-board.sh build` records through their own owners.
During that invocation it never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, or mutates backlog or task state.
Board answers are acted on later under the normal authority rules; this skill's board-wake section explicitly owns the guarded routing at that time.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the chat digest with a link or path to that report.
- `/bearings lavish` gathers a fresh bounded snapshot, rebuilds and arms the interactive fleet board (the "Lavish board mode" section below), and renders the chat digest with the board's URL inside it.
- Treat `file` and `lavish` only as explicit invocation options in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", "make a file", or "make a board" as file or lavish mode unless the invocation explicitly includes the standalone option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` and `/bearings lavish include PRs` compose the same way.
- A project scope comes only from the captain naming one or more registered projects, in the slash command or in the plain-language request; pass each registered name as `--repo <name>` and every mode composes with it.
- A name that matches no registered project is not a scope: say so in the lead-in and render the whole fleet rather than guessing which project was meant.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `bin/fm-bearings-snapshot.sh` at invocation time, with `--repo <name>` for each project in scope, and read its compact output.
   It is the single bounded, deterministic fleet-state source for Bearings and renders TOON by default.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, scope accounting, and output contract.
   When `decisions_open` is non-empty, run the same command again with `--fields bodies` added so each main-home decision's recorded note is in hand; a secondmate-owned decision's evidence is its snapshot row, because its record lives in that secondmate's home.
   Keep the default local-only read unless the captain asks to include PRs.
   For registered secondmates, use the snapshot's structured-home classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   A decision is simply a task held for the captain (`captain-hold-lifecycle`); every due, unblocked captain-held task appears under `decisions_open`, whatever its kind.
   A captain hold deferred by date sits under `gates` with its `until <date>:` reason until it is due, and a hold whose reason or body carries an explicit deferred/superseded marker is suppressed from the default view with an `omitted` disclosure.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   Every `gates` row carries `ready`; only a `ready` row is work the fleet could start now, and every other row stays queued with its blocker, date, or hold reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Captain's Call.
   A scoped snapshot keeps the fleet-integrity rows and discloses how many rows fell outside the scope; relay that count in one clause when it is non-zero, so a quiet project is never mistaken for a quiet fleet.

2. **Compose the chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now, weighing the decision evidence, and writing scannable captain-facing prose.
   The chat response is the position lead-in followed by the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same lead-in and four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only file-mode write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by the position lead-in expanded to a short paragraph: the scope, where things stand, and why it matters now.
   - **Captain's Call** - every open decision as a full decision block with its evidence, options, consequences, and recommendation, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state and any risk flagged, and the plans or main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - the prioritized what-next sequence: ready work first, then blocked, dated, and held work with each item's blocker, date, or hold reason, then any main-inventory integrity warning.
   After writing the file, return the chat digest and include the report path or link without adding a fifth section.
   For a richer review surface, offer `/bearings lavish` when the report has enough structure to deserve one, but only after the required digest is ready.

## Lavish board mode

`/bearings lavish` adds one deliverable beside the unchanged chat digest: the interactive fleet board, a myfirstmate-styled Lavish page where the captain answers Captain's Call items directly instead of replying in chat.
`bin/fm-bearings-board.sh` owns every board mechanic - the stable board path, fm-bearings-board.v1 payload validation, template injection, Lavish session establishment, the any-origin answer binding, and arm-if-absent registration - so the per-invocation work is composing the payload and running its `build`.

Compose the payload from the same snapshot with the same ranking judgment as the chat digest, plus these board rules:

- A Captain's Call decision key is the captain-held TASK ID from `decisions_open` (legacy `<origin>-decision-<key>` rows are already task ids); a merge card's key is `merge.<task-id>`; the Charted Next dispatch picker's key is `dispatch.charted`.
- Compose exactly one decision card per captain-held task id. When one task carries multiple questions, consolidate all of them and their options into that card; never emit duplicate cards with the same task-id key.
- Decision cards carry the same decision block as the chat, split into the card's fields: a short noun-phrase title, one-line `about` (the evidence) and `decide` (the question and consequence) context rows, and option labels with hints, with the recommended option marked.
- Card `type` (decision, merge, credential) is your composing judgment from the row's content; no backlog field types a card for you.
- When the card's task is a captain-gated WORK item (the answer should free it to proceed rather than complete it), set the card's `close: "release"` so the answer lifts the hold instead of closing the task; question-shaped items omit it.
- Every Captain's Call item and every Underway, Recently Landed, and Charted Next row carries an explicit `repo` field, copied from the snapshot row's `repo`; a null there is the deliberate genuinely-no-repo marker, in which case the template may show the internal id.
  Ids otherwise stay in the payload only as the routing channel, and composed reasons name blockers in plain words.
- A Charted Next row's `dispatchable` is the snapshot row's `ready`, never a reading of its reason text.

Run `build` once after composing the payload.
Its serve-first sequence publishes the board, establishes or resumes its Lavish session with `lavish-axi`, and only then binds and arms the polling source; use the session URL it prints in the chat digest.
Never bind or arm the board before that session exists.
Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll, and the watcher's ordinary reconcile restarts it, so no conversational turn ever blocks on the board.

### Handling a board wake

A board answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake. Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-bearings-board.sh path)"`, regardless of which answer kinds the result contains; then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Decision answers need no routing from you: the runner feeds the board's binding into `bin/fm-captain-hold.sh`'s one keyed-answer intake, which closes or releases each answered captain-held task at answer time; reconcile any `skipped:` key yourself with a direct `answer`, and when the captain's answer is "later", record it as a deferral with `tasks-axi hold <id> ... --until <date>` instead of a closure.
Route the non-decision keys yourself:

- `merge.<task-id>` is the captain's explicit merge order; follow the merge ruling below.
- `dispatch.charted` carries comma-separated task ids the captain picked to start now; verify each id against the current backlog - still queued, blocker and time gate actually clear - then dispatch through the normal lifecycle, and report any id that no longer qualifies instead of forcing it.

After handling, rebuild the board from a fresh snapshot so acted-on items leave Captain's Call, and echo every action taken in chat so the board and chat never diverge silently.

### The merge-click ruling (captain-decided)

A board "Merge now" answer IS the captain's explicit merge word for that one exact PR; ask no second confirmation.
The safeguards are mandatory, not optional: resolve the PR from the task's own `state/<task-id>.meta` `pr=` record, never from board bytes; re-verify at wake time that the PR is still open and CI-green; refuse and report a red or changed PR rather than merging it; merge only through `bin/fm-pr-merge.sh`; and echo every merge in chat with the full PR URL.
Only the exact answer value `merge` authorizes a merge; an answer carrying a freeform note is the captain's instruction text to read and act on with judgment, never an auto-merge.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders a position lead-in and then EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

0. **Position lead-in** - one to three plain sentences with no heading: the scope (the named projects or the whole fleet), the headline of where things stand, and why it matters now, drawn only from the snapshot.
   It carries the one-clause scope disclosure when a scoped read dropped rows, and it is where an unmatched project name is reported.
1. **Captain's Call** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Every item is a decision block in the shape below.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home, each as the outcome it delivered.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report, with a risk flagged in one clause wherever the row is not plain progress.
   Empty-state: "Nothing is underway."
4. **Charted Next** - the prioritized what-next sequence: ready work first, then work waiting on the fleet or a date, then action-free fleet-integrity warnings, never on the captain.
   Empty-state: "Nothing is queued."

A decision block is the captain's complete basis for the call, and it stays compact: at most six short lines, one per element, evidence first.

- The decision, in one sentence, with the project and how long it has been open from the snapshot's age.
- The evidence: only snapshot facts - the recorded reason and note, the owner, the full PR URL and its live checks state when PRs were included, and what the call is holding up (the `gates` rows blocked by it).
- The options: the ones the record states, verbatim in substance; when it states none, the two or three the evidence supports, labelled as proposed so recorded and proposed options are never confused.
- The consequences: one clause per option, including what leaving it open keeps waiting.
- The recommendation: one option, with its one-line reason.
- The smallest action that settles it: the reply word or phrase, the board answer, or the exact credential or login needed.

A merge item uses the same block with the full `https://...` URL, the checks state the snapshot recorded, and the risk level when the delivery path reported one; a credential item names exactly what is needed and what it unblocks.

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Captain's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free fleet-integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- A risk under Underway is a snapshot fact, stated as its consequence: a row whose state is not plain progress (blocked, paused, parked, failed, unknown), an unhealthy endpoint, a secondmate row whose freshness is stale or whose contradiction flag is set, or a paused external wait; a live blocked row is firstmate's to clear and stays Underway with the blocker named unless only the captain can clear it.
- Charted Next orders by readiness: every `ready` row first, in the snapshot's order, each named as ready to start; then rows blocked on other work, each with its blocker; then dated and held rows, each with the date or hold reason; then the integrity warnings last.
  Naming a row as ready never starts it.
- A secondmate's own row appears Underway only for `active_child_work`; `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the captain's action.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown`.
- Every decision carries its age from the snapshot: say how long it has been open, and present an aged one as a hypothesis to re-verify rather than a current fact.
- Never invent state beyond the snapshot: evidence, ages, checks states, blockers, and readiness come only from it, and an option or consequence you add is labelled as proposed.
- Relay an `omitted` disclosure only when it changes what the captain should conclude - hidden or deferred decisions, a bound that cut in-scope rows, an integrity gap, or a scope drop - and never list the routine opt-in surfaces.
- Include the required direct address to the captain inside the lead-in, one item, or an empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9: outcomes, consequences, and next decisions in the captain's nouns, one scannable line per item outside a decision block.
- Detailed plans, full gate reasons, and the longer evidence stay out of chat; file mode puts them in the report, while lavish mode puts only its payload-backed interactive detail on the board.
- In file mode, include the report path or link inside the digest without adding another heading.
- In lavish mode, include the board URL inside the digest the same way.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

During a digest/build invocation, this skill changes no fleet state beyond its explicit report or board artifacts, binding, and source registration.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any other `state/` or `data/` file during that invocation.
If the state gathered for the digest suggests an action, name it in its section and leave it to the normal lifecycle and configured authority.
On a later board wake, this read-only invocation rule yields to "Handling a board wake" and its guarded authority for captain-selected dispatches and merges.
