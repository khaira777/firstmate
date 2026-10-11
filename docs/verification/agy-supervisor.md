# Verification: Antigravity CLI (`agy`) as Primary Firstmate and Secondmate Supervisor

Active empirical facts for firstmate's agy primary and secondmate supervisor integration.
Upgrades Antigravity CLI from crewmate/scout-only to full Primary Firstmate and Secondmate supervisor.

## Architecture

Following Firstmate's native stop-hook park model (proven on Cursor and Claude Code), Antigravity runs as a supervisor through `.agents/hooks.json`:

1. **Stop Hook Park**: `bin/fm-turnend-guard-agy.sh` runs synchronously on every `Stop` event.
   When background crewmates or custom checks are in flight, the hook parks the turn boundary open on a watcher cycle (`bin/fm-watch-arm.sh`).
   Zero model tokens are consumed while parked.
   When an actionable event occurs, the hook returns `{"decision": "continue", "reason": "..."}` with the typed operational input envelope, waking the agent immediately.
2. **PreToolUse Seatbelt**: `PreToolUse` on `run_command` passes commands to `bin/fm-arm-pretool-check.sh --agy`.
   Dangerous watcher anti-patterns (such as backgrounding `bin/fm-watch.sh &` or piping output) and out-of-scope `cd` commands into project clones are rejected with `{"decision": "deny", "reason": "..."}`.
3. **Primary Scope Guard**: In linked crewmate/scout worktrees (`git_dir != git_common_dir`), hooks immediately allow (`{"decision": "allow"}` for PreToolUse, `{}` for Stop) via `fm_primary_scope_matches`.
4. **Session Lock**: `bin/fm-session-lock-lib.sh` recognizes `agy` in `FM_HARNESS_RE` and `FM_HARNESS_NAMES`, permitting agy sessions to acquire and hold the fleet lock.
5. **Secondmate Resolution**: `bin/fm-harness.sh secondmate` resolves `agy` when configured, and `bin/fm-spawn.sh` launches agy secondmate homes without refusal.

## Verification

The test suite in `tests/fm-agy-supervisor.test.sh` exercises:
- Session lock acquisition and ancestry identification for agy.
- Secondmate resolution and secondmate launch permission.
- PreToolUse hook allow (`{"decision": "allow"}`) for safe commands (`npm test`) and deny (`{"decision": "deny", ...}`) for watcher anti-patterns (`bin/fm-watch.sh &`).
- Stop hook fast-path allow (`{}`) when the fleet is idle.
- Stop hook park and continuation emission (`{"decision": "continue", "reason": ...}`) when in-flight work requires supervision.
- Strict primary scoping: safe allow in child worktrees (`{"decision": "allow"}` for PreToolUse, `{}` for Stop).
