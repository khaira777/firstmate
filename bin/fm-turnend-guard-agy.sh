#!/usr/bin/env bash
# Antigravity `Stop` and `PreToolUse` hook adapter for a firstmate PRIMARY session.
#
# Registered in tracked .agents/hooks.json. Antigravity runs hooks SYNCHRONOUSLY
# and awaits them:
#
#   PreToolUse  inspects `run_command` invocations. Rejects watcher anti-patterns
#               (such as backgrounding or piping watcher scripts) and dangerous
#               project cd commands before execution.
#
#   Stop        while supervision is needed, foregrounds bin/fm-watch-arm.sh and
#               holds the turn boundary open until the watcher closes with an
#               actionable wake, then returns that wake with {"decision": "continue", "reason": ...}.
#               Zero model tokens are spent while parked.
#               When the park cannot establish supervision, returns the shared
#               turn-end guard repair instruction as a bounded continuation.
#
# Scoped strictly to a primary checkout via fm_primary_scope_matches: in child
# crewmate/scout worktrees, both hooks immediately exit 0 with `{}`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
OWNER="$STATE/.agy-park-owner"
OWNER_LOCK="$STATE/.agy-park-owner.lock"
BUDGET_FILE="$STATE/.turnend-agy-blocks"
PARK_LOG="$STATE/.agy-park-exits.log"
PARK_LOG_LOCK="$STATE/.agy-park-exits.lock"
PARK_LOG_MAX_BYTES=${FM_AGY_PARK_LOG_MAX_BYTES:-262144}
PARK_LOG_KEEP_LINES=${FM_AGY_PARK_LOG_KEEP_LINES:-1000}

LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-180}
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-3}
ARM_ATTEMPTS=${FM_AGY_PARK_ATTEMPTS:-2}
POLL=${FM_AGY_PARK_POLL:-2}
LOCK_ATTEMPTS=${FM_AGY_LOCK_ATTEMPTS:-50}
PARK_MAX_SECONDS=${FM_AGY_PARK_MAX_SECONDS:-180}

case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$ARM_ATTEMPTS" in 1|2|3) : ;; *) ARM_ATTEMPTS=2 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac
case "$PARK_MAX_SECONDS" in ''|*[!0-9]*|0) PARK_MAX_SECONDS=180 ;; esac
case "$PARK_LOG_MAX_BYTES" in ''|*[!0-9]*|0) PARK_LOG_MAX_BYTES=262144 ;; esac
case "$PARK_LOG_KEEP_LINES" in ''|*[!0-9]*|0) PARK_LOG_KEEP_LINES=1000 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

PAYLOAD=$(cat 2>/dev/null || true)
# Detect whether this invocation is PreToolUse or Stop.
PRETOOL_MODE=0
if [ "${1:-}" = "--pretool" ]; then
  PRETOOL_MODE=1
elif printf '%s' "$PAYLOAD" | grep -q '"toolCall"'; then
  PRETOOL_MODE=1
fi

pretool_allow() {
  printf '{"decision":"allow"}\n'
  exit 0
}

[ -n "$PAYLOAD" ] || { if [ "$PRETOOL_MODE" -eq 1 ]; then pretool_allow; else echo "{}"; exit 0; fi; }
command -v jq >/dev/null 2>&1 || { if [ "$PRETOOL_MODE" -eq 1 ]; then pretool_allow; else echo "{}"; exit 0; fi; }

# Primary scope guard: child task worktrees must never run primary hooks.
if ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
  if [ "$PRETOOL_MODE" -eq 1 ]; then
    pretool_allow
  else
    echo "{}"
    exit 0
  fi
fi

# ==============================================================================
# PreToolUse Handler
# ==============================================================================
if [ "$PRETOOL_MODE" -eq 1 ]; then
  tool_name=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.name // empty' 2>/dev/null || true)
  if [ -n "$tool_name" ] && [ "$tool_name" != "run_command" ]; then
    pretool_allow
  fi
  cmd=$(printf '%s' "$PAYLOAD" | jq -r '(.toolCall.args.CommandLine // .toolInput.command // .tool_input.command // empty)' 2>/dev/null || true)
  if [ -z "$cmd" ]; then
    pretool_allow
  fi

  # 1. Watcher arm & background anti-pattern check
  CHECK_OUT=
  CHECK_RC=0
  CHECK_OUT=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-arm-pretool-check.sh" --agy 2>&1) || CHECK_RC=$?
  if [ "$CHECK_RC" -ne 0 ] || printf '%s' "$CHECK_OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$CHECK_OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
      printf '%s\n' "$CHECK_OUT"
    else
      reason=$(printf '%s' "$CHECK_OUT" | sed 's/"/\\"/g' | tr '\n' ' ')
      printf '{"decision":"deny","reason":"%s"}\n' "$reason"
    fi
    exit 0
  fi

  # 2. cd project guard
  CD_OUT=
  CD_RC=0
  CD_OUT=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-cd-pretool-check.sh" --agy 2>&1) || CD_RC=$?
  if [ "$CD_RC" -ne 0 ] || printf '%s' "$CD_OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$CD_OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
      printf '%s\n' "$CD_OUT"
    else
      reason=$(printf '%s' "$CD_OUT" | sed 's/"/\\"/g' | tr '\n' ' ')
      printf '{"decision":"deny","reason":"%s"}\n' "$reason"
    fi
    exit 0
  fi

  pretool_allow
fi

# ==============================================================================
# Stop Hook Handler (Park Model)
# ==============================================================================

PARK_SEQ=
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.conversationId // .sessionId // "unknown"' 2>/dev/null || printf 'unknown')
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) SESSION_ID=unknown ;; esac

TERMINATION_REASON=$(printf '%s' "$PAYLOAD" | jq -r '.terminationReason // .termination_reason // "unknown"' 2>/dev/null || printf 'unknown')
FULLY_IDLE=$(printf '%s' "$PAYLOAD" | jq -r '
  if has("fullyIdle") then (.fullyIdle | tostring)
  elif has("fully_idle") then (.fully_idle | tostring)
  else "absent" end
' 2>/dev/null || printf 'absent')
TRANSCRIPT_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.transcriptPath // .transcript_path // empty' 2>/dev/null || true)

park_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-256
}

park_log_append() {  # <reason> [detail]
  local reason=$1 detail=${2:-none} now pid seq size tmp raw i=0
  [ -d "$STATE" ] || return 0
  now=$(date +%s)
  pid=${BASHPID:-$$}
  seq=${PARK_SEQ:-none}
  while ! fm_lock_try_acquire "$PARK_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'at=%s\tpid=%s\tseq=%s\tsession=%s\treason=%s\tdetail=%s\n' \
    "$now" \
    "$pid" \
    "$(park_clean_field "$seq")" \
    "$(park_clean_field "${SESSION_ID:-unknown}")" \
    "$(park_clean_field "$reason")" \
    "$(park_clean_field "$detail")" >> "$PARK_LOG" 2>/dev/null || true
  size=$(wc -c < "$PARK_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$PARK_LOG_MAX_BYTES" ]; then
        tmp="$PARK_LOG.tmp.$pid"
        raw="$tmp.raw"
        tail -n "$PARK_LOG_KEEP_LINES" "$PARK_LOG" 2>/dev/null \
          | tail -c "$PARK_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^at=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$PARK_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$PARK_LOG_LOCK"
}

exit_nopark() {  # <reason> [detail]
  park_log_append "$1" "${2:-none}"
  echo "{}"
  exit 0
}

# Session lock verification: only the lock-owning session may supervise.
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in ''|*[!0-9]*) exit_nopark "session-lock-invalid" "lock_pid=${LOCK_PID:-empty}" ;; esac
  fm_harness_pid_alive "$LOCK_PID" && exit_nopark "session-lock-other-owner" "lock_pid=$LOCK_PID"
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit_nopark "session-lock-acquire-failed" "lock_pid=$LOCK_PID"
  fm_session_lock_owned_by_self "$STATE" || exit_nopark "session-lock-not-owned" "lock_pid=$LOCK_PID"
fi

OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$OWNER_ID" in ''|*[!0-9]*) exit_nopark "owner-id-invalid" "owner_id=${OWNER_ID:-empty}" ;; esac

EXECUTION_NUM=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("executionNum") then
    if ((.executionNum | type) == "number") then (.executionNum | floor) else 0 end
  elif has("executionNumber") then
    if ((.executionNumber | type) == "number") then (.executionNumber | floor) else 0 end
  else 0
  end
' 2>/dev/null || printf '0')
case "$EXECUTION_NUM" in ''|*[!0-9]*) EXECUTION_NUM=0 ;; esac

AGY_HISTORY_FILE="${FM_AGY_HISTORY_FILE:-${HOME:-}/.gemini/antigravity-cli/history.jsonl}"
CURSOR_FILE="$STATE/.agy-history-line"
LAST_PROCESSED_LINE=$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)
case "$LAST_PROCESSED_LINE" in ''|*[!0-9]*) LAST_PROCESSED_LINE=0 ;; esac

agy_history_count() {
  local file=$1 sid=$2 count=0
  [ -f "$file" ] || { echo 0; return 0; }
  if [ -n "$sid" ] && [ "$sid" != unknown ]; then
    count=$(grep "\"conversationId\":\"$sid\"" "$file" 2>/dev/null \
      | grep -Evc '"display"[[:space:]]*:[[:space:]]*"/' || true)
  else
    count=$(grep -Evc '"display"[[:space:]]*:[[:space:]]*"/' "$file" 2>/dev/null || true)
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  echo "$count"
}

INITIAL_HISTORY_LINES=$(agy_history_count "$AGY_HISTORY_FILE" "$SESSION_ID")
INITIAL_HISTORY_LINES=$((INITIAL_HISTORY_LINES + 0))

sync_history_cursor() {
  printf '%s\n' "${1:-$INITIAL_HISTORY_LINES}" > "$CURSOR_FILE" 2>/dev/null || true
}

agy_not_fully_idle() {
  case "$FULLY_IDLE" in
    false) return 0 ;;
    absent)
      [ "$TERMINATION_REASON" = "NO_TOOL_CALL" ] && return 0
      ;;
  esac
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    local open_tasks
    open_tasks=$(tail -n 100 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '
      if .type == "GENERIC" and (.content // "" | test("(^|\\n)Tool is running as a background task with task id: [A-Za-z0-9._-]+/task-[0-9]+")) then
        "OPEN:" + ((.content | capture("Tool is running as a background task with task id: (?<id>[A-Za-z0-9._-]+/task-[0-9]+)").id) // "")
      elif .type == "SYSTEM_MESSAGE" and (.content // "" | test("sender=[A-Za-z0-9._-]+/task-[0-9]+")) then
        "DONE:" + ((.content | capture("sender=(?<id>[A-Za-z0-9._-]+/task-[0-9]+)").id) // "")
      else empty end
    ' 2>/dev/null | awk -F: '
      $1 == "OPEN" && $2 != "" { open[$2] = 1 }
      $1 == "DONE" && $2 != "" { delete open[$2] }
      END { for (k in open) { print k; exit 0 } }
    ' 2>/dev/null || true)
    [ -n "$open_tasks" ] && return 0
  fi
  return 1
}

agy_queued_message_confirmed() {
  [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || return 0
  [ -f "$AGY_HISTORY_FILE" ] || return 0
  local hist_line hist_ts ui_ts
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != unknown ]; then
    hist_line=$(grep "\"conversationId\":\"$SESSION_ID\"" "$AGY_HISTORY_FILE" 2>/dev/null \
      | grep -Ev '"display"[[:space:]]*:[[:space:]]*"/' | tail -n 1 || true)
  else
    hist_line=$(grep -Ev '"display"[[:space:]]*:[[:space:]]*"/' "$AGY_HISTORY_FILE" 2>/dev/null | tail -n 1 || true)
  fi
  [ -n "$hist_line" ] || return 0
  hist_ts=$(printf '%s\n' "$hist_line" | jq -r '
    if (.timestamp | type) == "number" then (.timestamp / 1000 | floor) else empty end
  ' 2>/dev/null || true)
  case "$hist_ts" in ''|*[!0-9]*) return 0 ;; esac
  ui_ts=$(grep '"type":"USER_INPUT"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1 | jq -r '
    .created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601
  ' 2>/dev/null || true)
  case "$ui_ts" in ''|*[!0-9]*) return 0 ;; esac
  [ "$hist_ts" -gt "$((ui_ts + 2))" ]
}

lock_acquire_bounded() {  # <lock>
  local lock=$1 attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

budget_read() {
  local session count
  BUDGET_COUNT=0
  [ -f "$BUDGET_FILE" ] || return 0
  session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$session" = "$SESSION_ID" ] && BUDGET_COUNT=$count
  return 0
}

budget_write() {  # <count>
  local tmp="$BUDGET_FILE.tmp.$$" status=0
  [ ! -d "$BUDGET_FILE" ] || return 1
  printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$1" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null \
    || status=1
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

budget_reset() {
  rm -f "$BUDGET_FILE" 2>/dev/null
}

budget_reset_if_ours() {
  lock_acquire_bounded "$OWNER_LOCK" || exit_nopark "budget-reset-lock-timeout"
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit_nopark "budget-reset-superseded"
  fi
  budget_reset || {
    fm_lock_release "$OWNER_LOCK"
    exit_nopark "budget-reset-write-failed"
  }
  fm_lock_release "$OWNER_LOCK"
}

claim_park() {
  local seq tmp
  lock_acquire_bounded "$OWNER_LOCK" || return 1
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  PARK_SEQ=$((seq + 1))
  tmp="$OWNER.tmp.${BASHPID:-$$}"
  if ! printf 'seq=%s pid=%s updated_at=%s\n' "$PARK_SEQ" "${BASHPID:-$$}" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$OWNER" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$OWNER_LOCK"
  return 0
}

park_still_ours() {
  local seq
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  [ "$seq" = "$PARK_SEQ" ]
}

current_session_still_ours() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$OWNER_ID" ] || return 1
  fm_session_lock_owned_by_self "$STATE"
}

emit_continue() {  # <kind> <body> [reset-budget]
  local kind=$1 body=$2 reset_budget=${3-} encoded response
  fm_operational_input_encode "$kind" "$body" encoded || exit_nopark "encode-failed" "kind=$kind"
  response=$(jq -cn --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || exit_nopark "jq-encode-failed" "kind=$kind"
  lock_acquire_bounded "$OWNER_LOCK" || exit_nopark "continue-lock-timeout" "kind=$kind"
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit_nopark "continue-superseded" "kind=$kind"
  fi
  if [ "$reset_budget" = reset-budget ] && ! budget_reset; then
    fm_lock_release "$OWNER_LOCK"
    exit_nopark "continue-budget-reset-failed" "kind=$kind"
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

emit_repair_continue() {  # <reason> <arm-tail> <attempt>
  local reason=$1 arm_tail=$2 attempt_count=$3 prior count body encoded response
  park_still_ours || exit_nopark "repair-superseded"
  budget_read
  [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ] || exit_nopark "repair-budget-exhausted" "count=$BUDGET_COUNT budget=$BLOCK_BUDGET"
  prior=$BUDGET_COUNT
  count=$((prior + 1))

  body="TURN WOULD END BLIND - supervision is off. The hook-owned watcher park could not establish a live cycle after $attempt_count bounded attempts (nag $count of $BLOCK_BUDGET).
$arm_tail

$reason"
  fm_operational_input_encode turn-end-guard "$body" encoded || exit_nopark "repair-encode-failed"
  response=$(jq -cn --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || exit_nopark "repair-jq-failed"

  lock_acquire_bounded "$OWNER_LOCK" || exit_nopark "repair-lock-timeout"
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit_nopark "repair-superseded-under-lock"
  fi
  budget_read
  if [ "$BUDGET_COUNT" -ne "$prior" ] || ! budget_write "$count"; then
    fm_lock_release "$OWNER_LOCK"
    exit_nopark "repair-budget-write-failed"
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

claim_park || exit_nopark "claim-park-failed"

if [ "$EXECUTION_NUM" -ge "$LOOP_CEILING" ]; then
  if [ "$EXECUTION_NUM" -ne "$LOOP_CEILING" ]; then
    sync_history_cursor
    exit_nopark "loop-ceiling-exceeded" "execution_num=$EXECUTION_NUM ceiling=$LOOP_CEILING"
  fi
  if fm_supervision_needed "$STATE" "$GRACE"; then
    emit_continue turn-end-guard "FIRSTMATE SUPERVISION FOLLOW-UP CEILING REACHED - this session has taken $EXECUTION_NUM consecutive hook-driven turns without a captain message, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
  else
    sync_history_cursor
    exit_nopark "loop-ceiling-idle" "execution_num=$EXECUTION_NUM"
  fi
fi

# Away mode owns the watcher and its own triage; never park and never continue here.
if [ -e "$STATE/.afk" ]; then
  sync_history_cursor
  exit_nopark "afk-active"
fi

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  sync_history_cursor
  budget_reset_if_ours
  exit_nopark "supervision-not-needed"
fi

# Yield park while Antigravity background tasks or subagents are still running,
# so their completion <SYSTEM_MESSAGE> can be dequeued immediately.
if agy_not_fully_idle; then
  sync_history_cursor
  exit_nopark "not-fully-idle" "fully_idle=$FULLY_IDLE term=$TERMINATION_REASON"
fi

# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

ARM_OUT=
ARM_PID=
ACTIONABLE=0
HEALTHY=0
STAND_DOWN=0
STAND_DOWN_REASON=none
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
if fm_supervision_host_enabled "$CONFIG" agy; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi

trap '[ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT

# Detect messages queued during this turn
if [ "$LAST_PROCESSED_LINE" -gt 0 ] && [ "$INITIAL_HISTORY_LINES" -gt "$((LAST_PROCESSED_LINE + 1))" ]; then
  if agy_queued_message_confirmed; then
    sync_history_cursor "$((INITIAL_HISTORY_LINES - 1))"
    exit_nopark "queued-user-message" "last=$LAST_PROCESSED_LINE initial=$INITIAL_HISTORY_LINES"
  fi
fi

if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
  if herdr --session "${HERDR_SESSION:-main}" pane read "$HERDR_PANE_ID" --source visible 2>/dev/null | grep -q "queued messages"; then
    sync_history_cursor
    exit_nopark "herdr-queued-messages"
  fi
fi

sync_history_cursor "$INITIAL_HISTORY_LINES"

attempt=0
while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
  current_session_still_ours || exit_nopark "session-lost-before-arm" "attempt=$((attempt + 1))"
  attempt=$((attempt + 1))
  ARM_OUT=$(mktemp "$STATE/.agy-park-output.XXXXXX") || ARM_OUT=
  if [ "$HOST_MODE" -eq 1 ]; then
    FM_SUPERVISION_HOST_PRIMARY=agy "$SCRIPT_DIR/fm-supervision-host.sh" park >"${ARM_OUT:-/dev/null}" 2>&1 &
  elif [ -n "$ARM_OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  while kill -0 "$ARM_PID" 2>/dev/null; do
    if ! park_still_ours; then
      STAND_DOWN=1
      STAND_DOWN_REASON="park-superseded"
      break
    fi
    if ! current_session_still_ours; then
      STAND_DOWN=1
      STAND_DOWN_REASON="session-superseded"
      break
    fi
    if [ -e "$STATE/.afk" ]; then
      STAND_DOWN=1
      STAND_DOWN_REASON="afk-entered"
      break
    fi
    if ! fm_supervision_needed "$STATE" "$GRACE"; then
      STAND_DOWN=1
      STAND_DOWN_REASON="supervision-ended"
      break
    fi
    if [ -f "$AGY_HISTORY_FILE" ]; then
      current_history_lines=$(agy_history_count "$AGY_HISTORY_FILE" "$SESSION_ID")
      if [ "$((current_history_lines + 0))" -gt "$INITIAL_HISTORY_LINES" ]; then
        sync_history_cursor "$((current_history_lines - 1))"
        STAND_DOWN=1
        STAND_DOWN_REASON="user-message-history:${INITIAL_HISTORY_LINES}->${current_history_lines}"
        break
      fi
    fi
    if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
      if herdr --session "${HERDR_SESSION:-main}" pane read "$HERDR_PANE_ID" --source visible 2>/dev/null | grep -q "queued messages"; then
        STAND_DOWN=1
        STAND_DOWN_REASON="user-message-herdr"
        break
      fi
    fi
    sleep 0.5
  done
  if [ "$STAND_DOWN" -eq 1 ]; then
    kill "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
    ARM_PID=
    exit_nopark "stand-down" "reason=$STAND_DOWN_REASON"
  fi
  HOST_RC=0
  wait "$ARM_PID" 2>/dev/null || HOST_RC=$?
  ARM_PID=

  # Away mode may have been entered while parked: the daemon owns triage now.
  [ -e "$STATE/.afk" ] && exit_nopark "afk-after-arm"

  ACTIONABLE=0
  if [ -n "$ARM_OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$ARM_OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  if [ "$HOST_MODE" -eq 1 ]; then
    if [ -n "$ARM_OUT" ] && grep -q '^supervision-host stood down:' "$ARM_OUT" 2>/dev/null; then
      exit_nopark "supervision-host-stood-down"
    fi
    if [ "$HOST_RC" -gt 128 ] || [ -z "$ARM_OUT" ] || [ ! -s "$ARM_OUT" ]; then
      [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
      [ -z "$ARM_OUT" ] || rm -f "$ARM_OUT" 2>/dev/null
      ARM_OUT=
      continue
    fi
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating inside the shared grace window.
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
  [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
  ARM_OUT=
done

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  exit_nopark "supervision-not-needed-after-arm"
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  if [ "$HOST_MODE" -eq 1 ]; then
    WAKE=$(awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$ARM_OUT" 2>/dev/null)
  else
    WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  fi
  emit_continue watcher "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake." reset-budget
fi

if [ "$HEALTHY" -eq 1 ]; then
  budget_reset_if_ours
  exit_nopark "healthy-watcher-already-running"
fi

# If watcher still could not be established, invoke shared turn-end guard for repair instruction
GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXX") || exit_nopark "guard-mktemp-failed"
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy 2>"$GUARD_ERR"
GUARD_RC=$?
REASON=$(cat "$GUARD_ERR" 2>/dev/null || true)
rm -f "$GUARD_ERR" 2>/dev/null || true
[ "$GUARD_RC" -eq 2 ] || exit_nopark "turnend-guard-allow" "rc=$GUARD_RC"

[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
ARM_TAIL=
[ -n "$ARM_OUT" ] && ARM_TAIL=$(grep -E '^watcher:' "$ARM_OUT" 2>/dev/null | head -4)
emit_repair_continue "$REASON" "$ARM_TAIL" "$attempt"


