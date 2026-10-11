#!/usr/bin/env bash
# tests/fm-agy-supervisor.test.sh - tests for Antigravity CLI (`agy`) as a
# Firstmate Primary and Secondmate supervisor.
#
# Covers:
#   1. Session lock ancestry and ownership under `bin/fm-session-lock-lib.sh`.
#   2. Secondmate harness resolution and control-plane permission.
#   3. PreToolUse hook allow for safe commands and deny for watcher anti-patterns.
#   4. Stop hook fast-path allow when idle.
#   5. Stop hook synchronous park and continuation emission on actionable wake.
#   6. Strict primary scoping: hooks remain silent `{}` inside child worktrees.
#   7. Bounded repair continuations when supervision cannot be established.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-supervisor)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake agy process"

# Build a fake `agy` process so `ps -o comm=` reports exactly `agy`
cat > "$TMP_ROOT/fake-agy.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
"$CC_BIN" -o "$FAKEBIN/agy" "$TMP_ROOT/fake-agy.c" \
  || fail "could not build the fake agy process"
FAKE_AGY="$FAKEBIN/agy"

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard-agy.sh fm-turnend-guard.sh fm-arm-pretool-check.sh \
           fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-primary-scope-lib.sh \
           fm-supervision-lib.sh fm-wake-lib.sh fm-session-lock-lib.sh \
           fm-cursor-lib.sh fm-gemini-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-supervision-engine-lib.sh fm-control-lib.sh fm-path-lib.sh; do
    [ -f "$ROOT/bin/$f" ] && cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir"/bin/*.sh 2>/dev/null || true
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# ==============================================================================
# 1. Session Lock and Harness Identity Tests
# ==============================================================================

test_agy_session_lock_ancestry_identification() {
  local dir fake_ps out
  dir="$TMP_ROOT/session-lock-ident"
  fake_ps=$(fm_fakebin "$dir/ps-bin")
  mkdir -p "$dir/state"

  cat > "$fake_ps/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  200:comm=*) printf '%s\n' 'agy' ;;
  200:args=*) printf '%s\n' 'agy --prompt-interactive test' ;;
  200:ppid=*) printf '%s\n' 1 ;;
  *:comm=*) printf '%s\n' 'bash' ;;
  *:args=*) printf '%s\n' 'bash script' ;;
  *:ppid=*) printf '%s\n' 200 ;;
esac
SH
  chmod +x "$fake_ps/ps"

  out=$(PATH="$fake_ps:$BASE_PATH" bash -c '
    . "'"$ROOT/bin/fm-session-lock-lib.sh"'"
    fm_harness_ancestry_pid
  ')
  [ "$out" = "200" ] || fail "session lock ancestry failed to find agy pid 200, got: '$out'"

  # Test that an unrelated name is not matched
  cat > "$fake_ps/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  200:comm=*) printf '%s\n' 'magy' ;;
  200:args=*) printf '%s\n' 'magy --test' ;;
  200:ppid=*) printf '%s\n' 1 ;;
  *:comm=*) printf '%s\n' 'bash' ;;
  *:args=*) printf '%s\n' 'bash script' ;;
  *:ppid=*) printf '%s\n' 200 ;;
esac
SH
  chmod +x "$fake_ps/ps"
  if PATH="$fake_ps:$BASE_PATH" bash -c '
    . "'"$ROOT/bin/fm-session-lock-lib.sh"'"
    fm_harness_ancestry_pid
  ' 2>/dev/null; then
    fail "session lock matched unrelated name 'magy'"
  fi

  pass "session-lock: agy ancestry is identified and unrelated names are rejected"
}

test_agy_acquires_and_owns_session_lock() {
  local dir primary out
  dir="$TMP_ROOT/lock-acquisition"
  primary=$(make_primary_dir "$dir")

  out=$(FM_HOME="$primary" "$FAKE_AGY" -c '
    cd "$FM_HOME"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    . "$FM_HOME/bin/fm-session-lock-lib.sh"
    if fm_session_lock_owned_by_self "$FM_HOME/state"; then
      echo "OWNED"
    else
      echo "NOT_OWNED"
    fi
  ')
  [ "$out" = "OWNED" ] || fail "fake agy process failed to own session lock, got: '$out'"
  pass "session-lock: agy process acquires and verifies session lock ownership"
}

# ==============================================================================
# 2. Secondmate Resolution Tests
# ==============================================================================

test_secondmate_harness_resolves_agy() {
  local dir primary out
  dir="$TMP_ROOT/sm-resolve"
  primary=$(make_primary_dir "$dir")

  printf 'agy\n' > "$primary/config/secondmate-harness"
  out=$(FM_HOME="$primary" "$primary/bin/fm-harness.sh" secondmate)
  [ "$out" = "agy" ] || fail "expected secondmate to resolve agy, got '$out'"

  # Fallback to crew-harness
  rm -f "$primary/config/secondmate-harness"
  printf 'agy\n' > "$primary/config/crew-harness"
  out=$(FM_HOME="$primary" "$primary/bin/fm-harness.sh" secondmate)
  [ "$out" = "agy" ] || fail "expected secondmate to fallback to crew agy, got '$out'"

  # Control lib check
  out=$(bash -c '
    . "'"$ROOT/bin/fm-control-lib.sh"'"
    fm_control_harness_supports_kind agy secondmate && echo OK || echo FAIL
  ')
  [ "$out" = "OK" ] || fail "fm_control_harness_supports_kind agy secondmate returned false"

  pass "fm-harness: secondmate resolves agy and control-lib permits agy secondmates"
}

# ==============================================================================
# 3. PreToolUse Hook Tests
# ==============================================================================

test_pretool_allows_safe_command() {
  local dir primary out
  dir="$TMP_ROOT/pretool-allow"
  primary=$(make_primary_dir "$dir")

  out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"npm test"}}}' | \
    FM_HOME="$primary" "$primary/bin/fm-turnend-guard-agy.sh" --pretool)
  [ "$out" = '{"decision":"allow"}' ] || fail "expected safe command to return allow, got: '$out'"

  out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"git status"}}}' | \
    FM_HOME="$primary" "$primary/bin/fm-turnend-guard-agy.sh" --pretool)
  [ "$out" = '{"decision":"allow"}' ] || fail "expected git status to return allow, got: '$out'"

  pass "bin/fm-turnend-guard-agy.sh: PreToolUse allows clean commands with decision: allow"
}

test_pretool_denies_watcher_anti_patterns() {
  local dir primary out dec reason
  dir="$TMP_ROOT/pretool-deny"
  primary=$(make_primary_dir "$dir")

  out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch.sh &"}}}' | \
    FM_HOME="$primary" "$primary/bin/fm-turnend-guard-agy.sh" --pretool)
  dec=$(printf '%s' "$out" | jq -r '.decision // empty')
  [ "$dec" = "deny" ] || fail "expected deny decision for backgrounded watcher, got: '$out'"
  reason=$(printf '%s' "$out" | jq -r '.reason // empty')
  assert_contains "$reason" "bin/fm-watch.sh" "deny reason should reference the forbidden command"

  out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"./bin/fm-watch-arm.sh | tee log"}}}' | \
    FM_HOME="$primary" "$primary/bin/fm-turnend-guard-agy.sh" --pretool)
  dec=$(printf '%s' "$out" | jq -r '.decision // empty')
  [ "$dec" = "deny" ] || fail "expected deny decision for piped watcher arm, got: '$out'"

  pass "bin/fm-turnend-guard-agy.sh: PreToolUse denies watcher anti-patterns"
}

test_pretool_denies_cd_projects() {
  local dir primary out dec
  dir="$TMP_ROOT/pretool-cd"
  primary=$(make_primary_dir "$dir")

  out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/myclone"}}}' | \
    FM_HOME="$primary" "$primary/bin/fm-turnend-guard-agy.sh" --pretool)
  dec=$(printf '%s' "$out" | jq -r '.decision // empty')
  [ "$dec" = "deny" ] || fail "expected cd projects to be denied, got: '$out'"
  pass "bin/fm-turnend-guard-agy.sh: PreToolUse denies persistent cd into projects"
}

test_hooks_are_no_op_in_child_worktree() {
  local dir primary wt out
  dir="$TMP_ROOT/scoping"
  primary=$(make_primary_dir "$dir")

  # Create a linked worktree (child worktree)
  wt="$dir/worktrees/task-1"
  mkdir -p "$dir/worktrees"
  git -C "$primary" worktree add -q -b task-1-branch "$wt" HEAD

  # PreToolUse in worktree should return allow even for forbidden commands
  out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch.sh &"}}}' | \
    FM_ROOT_OVERRIDE="$wt" FM_HOME="$wt" "$primary/bin/fm-turnend-guard-agy.sh" --pretool)
  [ "$out" = '{"decision":"allow"}' ] || fail "expected allow in child worktree for PreToolUse, got: '$out'"

  # Stop hook in worktree should return {}
  out=$(printf '{"executionNum":1,"terminationReason":"model_stop"}' | \
    FM_ROOT_OVERRIDE="$wt" FM_HOME="$wt" "$primary/bin/fm-turnend-guard-agy.sh")
  [ "$out" = "{}" ] || fail "expected {} in child worktree for Stop hook, got: '$out'"

  pass "bin/fm-turnend-guard-agy.sh: hooks are inert no-ops inside linked child worktrees"
}

# ==============================================================================
# 4. Stop Hook Tests
# ==============================================================================

test_stop_hook_fast_path_when_idle() {
  local dir primary out
  dir="$TMP_ROOT/stop-idle"
  primary=$(make_primary_dir "$dir")

  out=$(FM_HOME="$primary" "$FAKE_AGY" -c '
    cd "$FM_HOME"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    printf "{\"executionNum\":1,\"terminationReason\":\"model_stop\"}" | \
      "$FM_HOME/bin/fm-turnend-guard-agy.sh"
  ')
  [ "$out" = "{}" ] || fail "expected {} on idle stop hook, got: '$out'"
  pass "bin/fm-turnend-guard-agy.sh: Stop hook returns {} immediately when fleet is idle"
}

test_stop_hook_parks_and_wakes_on_actionable_close() {
  local dir primary out dec reason
  dir="$TMP_ROOT/stop-park"
  primary=$(make_primary_dir "$dir")

  # Create an in-flight task to require supervision
  mkdir -p "$primary/state"
  printf 'task-123\n' > "$primary/state/in-flight"
  printf 'id=task-123\nkind=ship\n' > "$primary/state/task-123.meta"

  # Create mock bin/fm-watch-arm.sh that simulates a watcher wake
  cat > "$primary/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
sleep 0.1
printf 'signal: task task-123 finished\n'
SH
  chmod +x "$primary/bin/fm-watch-arm.sh"

  out=$(FM_HOME="$primary" FM_AGY_PARK_POLL=1 "$FAKE_AGY" -c '
    cd "$FM_HOME"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    printf "{\"executionNum\":1,\"conversationId\":\"conv-123\",\"terminationReason\":\"model_stop\"}" | \
      "$FM_HOME/bin/fm-turnend-guard-agy.sh"
  ')
  dec=$(printf '%s' "$out" | jq -r '.decision // empty')
  [ "$dec" = "continue" ] || fail "expected decision: continue on wake, got: '$out'"
  reason=$(printf '%s' "$out" | jq -r '.reason // empty')
  assert_contains "$reason" "firstmate watcher wake" "continuation reason lacked wake banner"
  assert_contains "$reason" "signal: task task-123 finished" "continuation reason lacked actionable event"

  pass "bin/fm-turnend-guard-agy.sh: Stop hook parks and emits continue on actionable wake"
}

test_stop_hook_bounded_repair_continuations() {
  local dir primary out dec
  dir="$TMP_ROOT/stop-repair"
  primary=$(make_primary_dir "$dir")

  # Create an in-flight task so supervision is needed
  printf 'task-456\n' > "$primary/state/in-flight"
  printf 'id=task-456\nkind=ship\n' > "$primary/state/task-456.meta"

  # Watcher that fails to start / exits immediately without wake or healthy beacon
  cat > "$primary/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$primary/bin/fm-watch-arm.sh"

  out=$(FM_HOME="$primary" FM_AGY_TURNEND_BLOCK_BUDGET=2 FM_AGY_PARK_ATTEMPTS=1 "$FAKE_AGY" -c '
    cd "$FM_HOME"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    for i in 1 2 3; do
      out=$(printf "{\"executionNum\":$i,\"conversationId\":\"conv-rep\",\"terminationReason\":\"model_stop\"}" | \
        "$FM_HOME/bin/fm-turnend-guard-agy.sh")
      printf "%s\n" "$out"
    done
  ')

  # Iteration 1 & 2 should continue with repair nag; iteration 3 should allow {}
  line1=$(printf '%s\n' "$out" | sed -n '1p')
  line2=$(printf '%s\n' "$out" | sed -n '2p')
  line3=$(printf '%s\n' "$out" | sed -n '3p')

  [ "$(printf '%s' "$line1" | jq -r '.decision')" = "continue" ] || fail "expected continue on nag 1, got: '$line1'"
  [ "$(printf '%s' "$line2" | jq -r '.decision')" = "continue" ] || fail "expected continue on nag 2, got: '$line2'"
  [ "$line3" = "{}" ] || fail "expected {} after exhausting budget, got: '$line3'"

  pass "bin/fm-turnend-guard-agy.sh: repair continuations are bounded and allow {} when exhausted"
}

test_stop_hook_history_scoping_ignores_sibling_agents() {
  local dir primary hist out dec out2
  dir="$TMP_ROOT/stop-history-scoping"
  primary=$(make_primary_dir "$dir")
  hist="$dir/history.jsonl"

  printf 'task-789\n' > "$primary/state/in-flight"
  printf 'id=task-789\nkind=ship\n' > "$primary/state/task-789.meta"

  cat > "$primary/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
sleep 0.1
printf 'signal: task task-789 wake\n'
SH
  chmod +x "$primary/bin/fm-watch-arm.sh"

  printf '{"conversationId":"conv-sibling","display":"cmd 1"}\n' > "$hist"
  printf '{"conversationId":"conv-sibling","display":"cmd 2"}\n' >> "$hist"
  printf '{"conversationId":"conv-ours","display":"prompt 1"}\n' >> "$hist"
  printf '0\n' > "$primary/state/.agy-history-line"

  out=$(FM_HOME="$primary" FM_AGY_HISTORY_FILE="$hist" "$FAKE_AGY" -c '
    cd "$FM_HOME"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    printf "{\"executionNum\":1,\"conversationId\":\"conv-ours\",\"terminationReason\":\"model_stop\"}" | \
      "$FM_HOME/bin/fm-turnend-guard-agy.sh"
  ')
  dec=$(printf '%s' "$out" | jq -r '.decision // empty')
  [ "$dec" = "continue" ] || fail "expected continue on wake despite sibling history lines, got: '$out'"

  printf '{"conversationId":"conv-ours","display":"prompt 2"}\n' >> "$hist"
  printf '{"conversationId":"conv-ours","display":"queued prompt 3"}\n' >> "$hist"
  out2=$(FM_HOME="$primary" FM_AGY_HISTORY_FILE="$hist" "$FAKE_AGY" -c '
    cd "$FM_HOME"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    printf "{\"executionNum\":2,\"conversationId\":\"conv-ours\",\"terminationReason\":\"model_stop\"}" | \
      "$FM_HOME/bin/fm-turnend-guard-agy.sh"
  ')
  [ "$out2" = "{}" ] || fail "expected {} on genuinely queued user message, got: '$out2'"

  pass "bin/fm-turnend-guard-agy.sh: scopes history to conversationId and releases on queued messages"
}

# --- Execution ---
test_agy_session_lock_ancestry_identification
test_agy_acquires_and_owns_session_lock
test_secondmate_harness_resolves_agy
test_pretool_allows_safe_command
test_pretool_denies_watcher_anti_patterns
test_pretool_denies_cd_projects
test_hooks_are_no_op_in_child_worktree
test_stop_hook_fast_path_when_idle
test_stop_hook_parks_and_wakes_on_actionable_close
test_stop_hook_bounded_repair_continuations
test_stop_hook_history_scoping_ignores_sibling_agents
