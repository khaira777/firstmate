#!/usr/bin/env bash
# Antigravity (agy) Stop-parked primary supervision hook and PreToolUse seatbelt.
#
# Registered in tracked .agents/hooks.json. Antigravity runs hooks SYNCHRONOUSLY
# and awaits them:
#
#   PreToolUse  inspects `run_command` invocations. Rejects watcher anti-patterns
#               (such as backgrounding or piping watcher scripts) and dangerous
#               project cd commands before execution.
#
#   Stop        parks the turn boundary on a tracked child, modeled on
#               bin/fm-turnend-guard-cursor.sh:
#               - bin/fm-watch-arm.sh, or bin/fm-supervision-host.sh park when the home
#                 runs the supervision host (fm_supervision_host_enabled ... agy).
#               - The child is polled every FM_AGY_PARK_POLL seconds (default 2) and the
#                 park waits on it under the 28800s hooks.json timeout, so an idle cycle
#                 spends no model turn.
#               - When FM_AGY_PARK_TIMEOUT is set to a positive number of seconds and
#                 that wait passes with the child still running, the child is stopped and
#                 {"decision":"continue","reason":"[supervision-park] ..."} returned.
#               - Actionable close wakes the agent with {"decision":"continue","reason":"<wake>"}.
#               - Non-actionable close beside a healthy watcher ends with {}.
#               - Stood down or superseded park ends with {}.
#               - Stand down immediately when a user message is queued in history.jsonl
#                 or Herdr pane, or when Antigravity background tasks/subagents are running.
#               - When the park cannot establish supervision after bounded attempts,
#                 bin/fm-turnend-guard.sh --agy owns the bounded repair nag.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

ARM_ATTEMPTS=${FM_AGY_PARK_ATTEMPTS:-2}
POLL=${FM_AGY_PARK_POLL:-2}
PARK_TIMEOUT=${FM_AGY_PARK_TIMEOUT:-0}
LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-180}

case "$ARM_ATTEMPTS" in 1|2|3) : ;; *) ARM_ATTEMPTS=2 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$PARK_TIMEOUT" in ''|*[!0-9]*) PARK_TIMEOUT=0 ;; esac
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac

PARK_LOG="$STATE/.agy-park-exits.log"
PARK_LOG_LOCK="$STATE/.agy-park-exits.lock"
PARK_LOG_MAX_BYTES=${FM_AGY_PARK_LOG_MAX_BYTES:-262144}
PARK_LOG_KEEP_LINES=${FM_AGY_PARK_LOG_KEEP_LINES:-1000}

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

allow_stop() {
  printf '{}\n'
  exit 0
}

continue_turn() {  # <reason>
  jq -cn --arg r "$1" '{decision:"continue",reason:$r}'
  exit 0
}

pretool_allow() {
  printf '{"decision":"allow"}\n'
  exit 0
}

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

PAYLOAD=$(cat 2>/dev/null || true)

PRETOOL_MODE=0
if [ "${1:-}" = "--pretool" ]; then
  PRETOOL_MODE=1
elif printf '%s' "$PAYLOAD" | grep -q '"toolCall"'; then
  PRETOOL_MODE=1
fi

[ -n "$PAYLOAD" ] || { if [ "$PRETOOL_MODE" -eq 1 ]; then pretool_allow; else allow_stop; fi; }
command -v jq >/dev/null 2>&1 || { if [ "$PRETOOL_MODE" -eq 1 ]; then pretool_allow; else allow_stop; fi; }

# Primary scope guard: child task worktrees must never run primary hooks.
if ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
  if [ "$PRETOOL_MODE" -eq 1 ]; then
    pretool_allow
  else
    allow_stop
  fi
fi

# ==============================================================================
# PreToolUse Handler (Compatibility & Standalone)
# ==============================================================================
if [ "$PRETOOL_MODE" -eq 1 ]; then
  tool_name=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.name // empty' 2>/dev/null || true)
  if [ -n "$tool_name" ] && [ "$tool_name" != "run_command" ]; then
    pretool_allow
  fi
  cmd=$(printf '%s' "$PAYLOAD" | jq -r '(.toolCall.args.CommandLine // .toolCall.args.command // .toolInput.command // .tool_input.command // empty)' 2>/dev/null || true)
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
# Stop Hook Handler
# ==============================================================================

TERM_REASON=$(printf '%s' "$PAYLOAD" | jq -r '.terminationReason // .termination_reason // empty' 2>/dev/null || true)
case "$TERM_REASON" in
  USER_CANCELED|ERROR|MAX_INVOCATIONS|MAX_FORCED_INVOCATIONS|MAX_TOKEN_BUDGET_EXCEEDED)
    allow_stop
    ;;
  ""|NO_TOOL_CALL|model_stop|unknown)
    ;;
  *)
    allow_stop
    ;;
esac

EXEC_NUM=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then ""
  elif has("executionNum") then
    if ((.executionNum | type) == "number") then (.executionNum | floor | tostring) else "" end
  elif has("executionNumber") then
    if ((.executionNumber | type) == "number") then (.executionNumber | floor | tostring) else "" end
  else ""
  end
' 2>/dev/null || true)

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.conversationId // .sessionId // "unknown"' 2>/dev/null || printf 'unknown')
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) SESSION_ID=unknown ;; esac

FULLY_IDLE=$(printf '%s' "$PAYLOAD" | jq -r '
  if has("fullyIdle") then (.fullyIdle | tostring)
  elif has("fully_idle") then (.fully_idle | tostring)
  else "absent" end
' 2>/dev/null || printf 'absent')
TRANSCRIPT_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.transcriptPath // .transcript_path // empty' 2>/dev/null || true)

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
      if printf '%s' "$PAYLOAD" | grep -q '"executionNumber"'; then
        [ "$TERM_REASON" = "NO_TOOL_CALL" ] && return 0
      fi
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

if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$LOCK_PID" || allow_stop
  fm_harness_pid_alive "$LOCK_PID" && allow_stop
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || allow_stop
  fm_session_lock_owned_by_self "$STATE" || allow_stop
fi

# Away mode owns the watcher and its own triage; never park and never wake.
[ -e "$STATE/.afk" ] && allow_stop

# The ceiling bounds hook-driven turns.
if [ -n "$EXEC_NUM" ] && [ "$EXEC_NUM" -ge "$LOOP_CEILING" ]; then
  [ "$EXEC_NUM" -eq "$LOOP_CEILING" ] || allow_stop
  fm_supervision_needed "$STATE" "$GRACE" || allow_stop
  continue_turn "FIRSTMATE SUPERVISION FOLLOW-UP CEILING REACHED - this session has taken $EXEC_NUM consecutive hook-driven turns, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
fi

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  sync_history_cursor
  park_log_append "supervision-not-needed"
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

# Yield park while Antigravity background tasks or subagents are still running
if agy_not_fully_idle; then
  sync_history_cursor
  park_log_append "not-fully-idle" "fully_idle=$FULLY_IDLE term=$TERM_REASON"
  allow_stop
fi

# Detect messages queued during this turn
if [ "$LAST_PROCESSED_LINE" -gt 0 ] && [ "$INITIAL_HISTORY_LINES" -gt "$((LAST_PROCESSED_LINE + 1))" ]; then
  if agy_queued_message_confirmed; then
    sync_history_cursor "$((INITIAL_HISTORY_LINES - 1))"
    park_log_append "queued-user-message" "last=$LAST_PROCESSED_LINE initial=$INITIAL_HISTORY_LINES"
    allow_stop
  fi
fi

if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
  if herdr --session "${HERDR_SESSION:-main}" pane read "$HERDR_PANE_ID" --source visible 2>/dev/null | grep -q "queued messages"; then
    sync_history_cursor
    park_log_append "herdr-queued-messages"
    allow_stop
  fi
fi

sync_history_cursor "$INITIAL_HISTORY_LINES"

mkdir -p "$STATE" 2>/dev/null || true
PARK_OWNER_FILE="$STATE/.agy-park-owner"
PARK_OWNER="$$:$(date +%s):${RANDOM:-0}"
PARK_SEQ=$PARK_OWNER
printf '%s\n' "$PARK_OWNER" > "$PARK_OWNER_FILE"

park_still_ours() {
  [ "$(cat "$PARK_OWNER_FILE" 2>/dev/null || true)" = "$PARK_OWNER" ]
}

ARM_OUT=
ARM_PID=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
if fm_supervision_host_enabled "$CONFIG" agy; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi

# Never leave a park child or its capture file behind, on any exit path.
trap '[ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT

waited=0
attempt=0
while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
  [ "$PARK_TIMEOUT" -eq 0 ] || [ "$waited" -lt "$PARK_TIMEOUT" ] || break
  attempt=$((attempt + 1))
  ARM_OUT=$(mktemp "$STATE/.agy-park-output.XXXXXX") || { ARM_OUT=; break; }
  if [ "$HOST_MODE" -eq 1 ]; then
    FM_SUPERVISION_HOST_PRIMARY=agy "$SCRIPT_DIR/fm-supervision-host.sh" park >"$ARM_OUT" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  fi
  ARM_PID=$!
  STAND_DOWN=0
  STAND_DOWN_REASON=none
  while kill -0 "$ARM_PID" 2>/dev/null; do
    if ! park_still_ours || ! fm_session_lock_owned_by_self "$STATE" || [ -e "$STATE/.afk" ]; then
      STAND_DOWN=1
      STAND_DOWN_REASON="superseded-or-afk"
      break
    fi
    if ! fm_supervision_needed "$STATE" "$GRACE"; then
      STAND_DOWN=1
      STAND_DOWN_REASON="supervision-ended"
      break
    fi
    if [ "$PARK_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$PARK_TIMEOUT" ]; then
      kill "$ARM_PID" 2>/dev/null
      ARM_PID=
      continue_turn "[supervision-park] No actionable wake arrived within ${PARK_TIMEOUT}s while supervision is still needed. End your turn briefly so the Antigravity Stop hook can re-park on the next turn boundary."
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
    sleep "$POLL"
    waited=$((waited + POLL))
  done

  if [ "$STAND_DOWN" -eq 1 ]; then
    kill "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
    ARM_PID=
    park_log_append "stand-down" "reason=$STAND_DOWN_REASON"
    allow_stop
  fi

  HOST_RC=0
  wait "$ARM_PID" 2>/dev/null || HOST_RC=$?
  ARM_PID=

  park_still_ours || allow_stop
  [ -e "$STATE/.afk" ] && allow_stop

  if [ -n "$ARM_OUT" ] && grep -Eq "$ACTIONABLE_RE" "$ARM_OUT" 2>/dev/null; then
    ACTIONABLE=1
    break
  fi

  if [ "$HOST_MODE" -eq 1 ]; then
    grep -q '^supervision-host stood down:' "$ARM_OUT" 2>/dev/null && allow_stop
    if [ "$HOST_RC" -gt 128 ] || [ ! -s "$ARM_OUT" ]; then
      rm -f "$ARM_OUT" 2>/dev/null
      ARM_OUT=
      continue
    fi
  fi

  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
  [ -z "$ARM_OUT" ] || rm -f "$ARM_OUT" 2>/dev/null
  ARM_OUT=
done

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  if [ "$HOST_MODE" -eq 1 ]; then
    WAKE=$(awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$ARM_OUT" 2>/dev/null)
  else
    WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  fi
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  continue_turn "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake."
fi

if [ "$HEALTHY" -eq 1 ]; then
  rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
  allow_stop
fi

# The park could not establish supervision: the shared guard owns the bounded
# repair nag and its {} fail-open.
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --agy
exit 0
