# `gh pr view --json statusCheckRollup` payloads

These files hold the payload shapes GitHub returns for a pull request's check rollup, kept as data so `tests/fm-pr-merge.test.sh` can replay them through the real `-q` filter `bin/fm-pr-merge.sh` sends to the CLI.
Without them the suite only ever sees rows a mock already formatted the way that filter would have, so the filter itself is never evaluated.

A `CheckRun` node carries a `conclusion` and no `state`.
A `StatusContext` node, which is how external CI posts through the statuses API, carries a `state` and a `context` rather than a `name`.
Reading only the conclusion is what once let a genuinely red external check merge as pending, so both node shapes are represented here.

| file | what it records |
| --- | --- |
| `check-run-failure.json` | a workflow job that failed (`conclusion: FAILURE`) |
| `commit-status-failure.json` | external CI reporting failure through a commit status (`state: FAILURE`) |
| `expected-required-status.json` | a required status context declared but not yet reported (`state: EXPECTED`) |
| `all-skipped.json` | a rollup that was entirely path-filtered or cancelled |
| `unreadable.json` | a payload whose rollup field is not an array, so the check state cannot be established |
