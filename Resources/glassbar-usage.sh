#!/bin/bash
# glassbar-usage.sh — emits one JSON object with live Claude Code + Codex state.
#
# Claude: real subscription limits from the SAME endpoint `/usage` uses
#         (GET https://api.anthropic.com/api/oauth/usage with the Keychain
#         OAuth token) → five_hour + seven_day utilization %, resets, plus the
#         list of live sessions (name / cwd / status) from ~/.claude/sessions.
# Codex:  5-hour + weekly % and resets from the newest ~/.codex/sessions
#         rollout, plus live codex CLI sessions.
#
# Requires: jq, curl, security (all preinstalled). Degrades gracefully.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
JQ=$(command -v jq || echo jq)

# ---------------- Claude: real /usage limits ----------------
CU='{}'
RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
if [ -n "$RAW" ]; then
  AT=$(printf '%s' "$RAW" | "$JQ" -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null)
  [ -z "$AT" ] && AT="$RAW"
  resp=$(curl -s --max-time 6 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $AT" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null)
  if printf '%s' "$resp" | "$JQ" -e 'has("five_hour")' >/dev/null 2>&1; then CU="$resp"; fi
fi

# ---------------- Claude: live sessions ----------------
CS=$(
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -f "$f" ] || continue
    pid=$("$JQ" -r '.pid // empty' "$f" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    "$JQ" -c '{name:(.name // (.sessionId[0:8]) // "session"), cwd:(.cwd // ""),
               pid:.pid, status:(.status // "idle")}' "$f" 2>/dev/null
  done | "$JQ" -s '.' 2>/dev/null
)
[ -z "$CS" ] && CS='[]'

# ---------------- Codex: limits from newest rollout ----------------
x_primary_pct=0; x_primary_reset=0; x_weekly_pct=0; x_weekly_reset=0
SESS="$HOME/.codex/sessions"
newest=$(find "$SESS" -name 'rollout-*.jsonl' 2>/dev/null | sort | tail -1)
if [ -n "$newest" ]; then
  rl=$(grep 'rate_limits' "$newest" 2>/dev/null | tail -1)
  if [ -n "$rl" ]; then
    pick='(.. | objects | select(has("rate_limits")) | .rate_limits)'
    x_primary_pct=$(printf '%s'   "$rl" | "$JQ" -r "$pick.primary.used_percent   // 0" 2>/dev/null | head -1)
    x_primary_reset=$(printf '%s' "$rl" | "$JQ" -r "$pick.primary.resets_at      // 0" 2>/dev/null | head -1)
    x_weekly_pct=$(printf '%s'    "$rl" | "$JQ" -r "$pick.secondary.used_percent // 0" 2>/dev/null | head -1)
    x_weekly_reset=$(printf '%s'  "$rl" | "$JQ" -r "$pick.secondary.resets_at    // 0" 2>/dev/null | head -1)
  fi
fi

# ---------------- Codex: live sessions (leader processes) ----------------
XS=$(
  pids=$(pgrep -x codex 2>/dev/null)
  declare -a leaders=()
  for pid in $pids; do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    pcomm=$(ps -o comm= -p "$ppid" 2>/dev/null)
    [ "$(basename "$pcomm" 2>/dev/null)" = "codex" ] && continue   # skip workers
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    name=$(basename "${cwd:-codex}")
    "$JQ" -nc --arg name "$name" --arg cwd "$cwd" --argjson pid "$pid" \
      '{name:$name, cwd:$cwd, pid:$pid, status:"running"}'
  done | "$JQ" -s 'unique_by(.cwd)' 2>/dev/null
)
[ -z "$XS" ] && XS='[]'

# ---------------- assemble ----------------
"$JQ" -n \
  --argjson cu "$CU" --argjson cs "$CS" --argjson xs "$XS" \
  --argjson xpp "${x_primary_pct:-0}" --argjson xpr "${x_primary_reset:-0}" \
  --argjson xwp "${x_weekly_pct:-0}"  --argjson xwr "${x_weekly_reset:-0}" '
  def iso2epoch: if (type=="string" and length>=19)
    then ((.[0:19]+"Z")|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime) else 0 end;
  {
    claude: {
      ok: (if ($cu|has("five_hour")) then 1 else 0 end),
      fiveHourPercent:  ($cu.five_hour.utilization // 0),
      fiveHourResetsAt: (($cu.five_hour.resets_at // "") | iso2epoch),
      weekPercent:      ($cu.seven_day.utilization // 0),
      weekResetsAt:     (($cu.seven_day.resets_at // "") | iso2epoch),
      sonnetPercent:    ($cu.seven_day_sonnet.utilization // -1),
      opusPercent:      ($cu.seven_day_opus.utilization // -1),
      sessions: $cs
    },
    codex: {
      primaryPercent: $xpp, primaryResetsAt: $xpr,
      weeklyPercent:  $xwp, weeklyResetsAt:  $xwr,
      sessions: $xs
    }
  }'
