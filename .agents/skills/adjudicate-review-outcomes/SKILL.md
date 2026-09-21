---
name: adjudicate-review-outcomes
description: >-
  Adjudicate review findings a colleague or an automated reviewer already posted into a pull request conversation, decide FIX or REFUSE for each with stated reasoning, and publish one disposition comment back onto that same pull request.
  Use when the captain invokes /adjudicate-review-outcomes, or before answering review findings that already sit on a pull request.
  Not for authoring a review, not for no-mistakes ask-user gate findings, and not for deciding whether a pull request may merge.
user-invocable: true
metadata:
  internal: true
---

# adjudicate-review-outcomes

Load this when review findings already exist on a pull request and somebody has to answer them.
The deliverable is two things: the changes the accepted findings require, and one disposition comment posted back into that same pull request conversation.
This skill decides posted findings only; merge authority stays with `AGENTS.md` sections 1 and 7, and a no-mistakes ask-user gate finding is a different object owned by `ask-user-authority`.

## The disposition comment is the deliverable

Posting the disposition back into the same pull request conversation is the point of this skill, not a formality at the end of it.
The record goes as a comment on the pull request the findings were raised on, never an issue, a file in the repository, a branch note, or a reply in chat, because the colleague who raised them reads that conversation and nothing else.
It covers every finding raised there, fixed, refused, and present alike, so that colleague can see each one answered without having to ask.
If a run ends without that comment posted, the work is not done: say so plainly and name what is still unanswered, rather than reporting success.

It is a public artifact on a shared repository, written for the colleague who raised the findings rather than for us.

- It must be readable to someone with no context on our internal process: no internal vocabulary, task identifiers, private paths, or process names.
- It must name the head sha judged, so the reader can reproduce every verdict against the same tree.
- It must carry no agent name and address nobody by title or rank, because `AGENTS.md` section 1 forbids direct address outside chat and a review reply is exactly where it slips in.

One comment, containing:

1. The head sha judged.
2. The review surface enumerated, naming each comment, review, and inline thread with its finding count, including the surfaces that held none.
3. A per-finding table of severity, the finding restated in your own words, and its disposition: FIXED with the commit, REFUSED with the evidence, PRESENT with what remains, or PRESENT-upstream with the owner.
4. An explicit statement that nothing was set aside unexamined.

Post it once the accepted fixes are committed and pushed, so every commit the table names already exists.

## Priority rule

- Blocker and major findings are the priority: every one of them ends FIXED or REFUSED, and none may be left merely recorded.
- Minor findings are fixed only when the fix is easy and fast; otherwise record them PRESENT with a one-line reason.
- Nits are optional and may simply be listed.

The reviewer's severity is a claim, not a verdict.
When your own measurement contradicts it, state the severity you measured and the evidence for it, rather than quietly relabelling a blocker as a nit to escape the rule above.

## Rules this run must satisfy

Each rule below was paid for by a real failure, so each one states its reason: a rule with no reason gets rationalised away at the moment it becomes inconvenient.

1. **Enumerate the review surface rather than assuming it.**
   Issue comments, formal reviews, and inline review threads are three different surfaces, and a finding on any one of them counts.
   Report the count for every surface including the empty ones, because an adjudication is trustworthy when it checked all three and said which two were empty, not when it happened to find something on the first.
2. **Check the head each review was computed against.**
   Reviews computed against a stale tree re-raise findings that are already closed, and one such comment stated its own base, which proved it was twelve commits behind.
   Staleness is a finding about the review, not a reason to dismiss its substance: re-measure the claim at the current head before accepting or rejecting it.
3. **Re-measure every claim and inherit no verdict.**
   An earlier round's write-up describes a tree that no longer exists, so carrying its verdict forward asserts something nobody checked.
4. **A refusal needs evidence, not an opinion.**
   Quote the closing code, the contract clause, or the measurement that disproves the finding, because a refusal without evidence is indistinguishable from not having looked.
5. **Over-enforcement is a defect, not a safe default.**
   A finding that asks the product to refuse something a client is entitled to configure must be REFUSED, citing that principle, because shipping the stricter behavior "to be safe" breaks a guarantee the product already made.
6. **Say "not examined" where that is the truth.**
   A silently dropped finding is exactly what this record exists to prevent, and an honest gap can be closed by whoever reads it.
   For a blocker or major, "not examined" is a failed run rather than an allowed disposition: go back and examine it.
7. **Fixes need red-then-green with a named failing assertion plus a mutation proof.**
   A non-zero exit is not evidence, since it can come from a syntax error, a missing fixture, or an unrelated case.
   Record the named assertion that fails before the fix, that it passes after, and that mutating the value the fix installs makes it fail again, which is what proves the assertion is actually bound to the behavior.
8. **Do not fix beyond the finding.**
   Correcting the prose of your own audit is not adjudication, and one lane spent eight rounds editing its own commentary before it was stopped.
   Anything worth doing beyond the finding is follow-up work to name in the disposition, not scope to take now.
9. **Stay in the repo the finding lives in.**
   When the correct fix belongs to another repository or to a byte-pinned vendored contract, record it PRESENT-upstream and name the owner.
   Hand-editing a pinned contract forges it: the bytes stop matching what the owner published, and every later verification against that pin becomes meaningless.

## Operating sequence

1. Identify the pull request and read its current head sha; every judgment in this run is measured against that head.
2. Enumerate all three review surfaces and record each comment, review, and inline thread with its finding count, using `gh-axi` and its current help rather than remembered flags.
3. Extract every finding into one list with the reviewer's severity and the head that review was computed against.
4. Re-measure each finding at the current head, then decide its disposition under the priority rule and the rules above.
5. Implement the accepted fixes, each scoped to its own finding, each proved red-then-green with a named assertion and a mutation proof.
6. Commit and push the fixes so the disposition can name real commits.
7. Check the list before posting: every blocker and major carries FIXED or REFUSED, every remaining finding carries a disposition, and every finding raised on any surface appears.
8. Post the single disposition comment to that same pull request, then report the outcome and the comment's URL.
