Mode: omp background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-watch-arm.sh` as its own omp background async job.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
   Do not invent a wake from an attach-status line alone.
7. Treat any `watcher: FAILED ...` line as an alarm and repair it before ending the turn.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
8. When the background async job completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle them, then start exactly one fresh background async job.
9. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same omp background async job mechanism and treat its `watcher: started ...` line as proof that the replacement cycle is live.
10. Do not send idle progress while the watcher is parked.

omp's background async-job completion, delivered back as a follow-up, is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
The primary turn-end guard `.omp/extensions/fm-primary-turnend-guard.ts` auto-loads from omp's tracked `.omp/extensions/` root and blocks a blind turn end through its `session_stop` handler until supervision is resumed.
