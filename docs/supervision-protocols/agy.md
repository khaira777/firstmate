Mode: Antigravity stop-hook-owned park.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the `Stop` hook (`bin/fm-turnend-guard-agy.sh`), never by you.
   Antigravity runs that hook synchronously and awaits it, so every turn end while supervision is needed parks the turn boundary open on one home-scoped watcher cycle, with no model command and no model tokens spent while parked.
3. An actionable close wakes you as a continuation turn carrying the `watcher` operational kind.
   On that wake, run `bin/fm-wake-drain.sh` first and handle it.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end parks again automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
4. The captain keeps control while the hook is parked.
   A message typed into a parked Antigravity pane is accepted, while the older park stands down when superseded.
   The private supersession records are `state/.agy-park-owner` and its short publication and commit lock `state/.agy-park-owner.lock`.
5. On a `turn-end-guard` continuation, the park could not establish a live cycle.
   Inspect the watcher startup path rather than turning the notice into a repeating manual-arm loop; the nag is bounded by `FM_AGY_TURNEND_BLOCK_BUDGET` (default 3) and then stops on its own.
6. Treat `watcher: started ...` and `watcher: attached ...` inside park output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a continuation and the next park.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. Waiting on the hook-owned park is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the `Stop` hook runs as its own tracked child.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
