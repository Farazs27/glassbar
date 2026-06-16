#!/bin/bash
# glassbar-usage.sh — emits a single JSON object with Claude Code + Codex usage.
#
# Claude: today / this-week tokens+cost and the active 5-hour block (via `ccusage`).
# Codex:  5-hour + weekly usage % and reset times, plus session/today tokens,
#         parsed from the newest ~/.codex/sessions rollout.
#
# Requires: ccusage (npm i -g ccusage), jq. Degrades to zeros if absent.

# Make tools discoverable even when launched by launchd (no interactive PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
export PATH

CC=$(command -v ccusage || true)
JQ=$(command -v jq || echo jq)
TODAY=$(date +%Y%m%d)

# ---------- Claude (via ccusage) ----------
c_today_tokens=0; c_today_cost=0
c_week_tokens=0;  c_week_cost=0
c_block_tokens=0; c_block_cost=0; c_block_reset=0
if [ -n "$CC" ]; then
  d=$("$CC" daily --json --since "$TODAY" --until "$TODAY" 2>/dev/null)
  c_today_tokens=$(printf '%s' "$d" | "$JQ" -r '(.totals.totalTokens // .daily[-1].totalTokens // 0)|floor' 2>/dev/null)
  c_today_cost=$(printf '%s' "$d"   | "$JQ" -r '(.totals.totalCost  // .daily[-1].totalCost  // 0)' 2>/dev/null)

  w=$("$CC" weekly --json 2>/dev/null)
  c_week_tokens=$(printf '%s' "$w" | "$JQ" -r '(.weekly[-1].totalTokens // 0)|floor' 2>/dev/null)
  c_week_cost=$(printf '%s' "$w"   | "$JQ" -r '(.weekly[-1].totalCost  // 0)' 2>/dev/null)

  b=$("$CC" blocks --active --json 2>/dev/null)
  c_block_tokens=$(printf '%s' "$b" | "$JQ" -r '([.blocks[]?|select(.isActive==true)]|first.totalTokens)//0|floor' 2>/dev/null)
  c_block_cost=$(printf '%s' "$b"   | "$JQ" -r '([.blocks[]?|select(.isActive==true)]|first.costUSD)//0' 2>/dev/null)
  bend=$(printf '%s' "$b"           | "$JQ" -r '([.blocks[]?|select(.isActive==true)]|first.endTime)//empty' 2>/dev/null)
  if [ -n "$bend" ]; then
    iso="${bend%.*}"; iso="${iso%Z}"
    c_block_reset=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null || echo 0)
  fi
fi

# ---------- Codex (parse newest rollout) ----------
x_primary_pct=0; x_primary_reset=0
x_weekly_pct=0;  x_weekly_reset=0
x_session_tokens=0; x_today_tokens=0
SESS="$HOME/.codex/sessions"
rlpick='(.. | objects | select(has("rate_limits")) | .rate_limits)'
ttpick='(.. | objects | select(has("total_token_usage")) | .total_token_usage.total_tokens)'

newest=$(find "$SESS" -name 'rollout-*.jsonl' 2>/dev/null | sort | tail -1)
if [ -n "$newest" ]; then
  rl=$(grep 'rate_limits' "$newest" 2>/dev/null | tail -1)
  if [ -n "$rl" ]; then
    x_primary_pct=$(printf '%s'   "$rl" | "$JQ" -r "$rlpick.primary.used_percent   // 0" 2>/dev/null | head -1)
    x_primary_reset=$(printf '%s' "$rl" | "$JQ" -r "$rlpick.primary.resets_at      // 0" 2>/dev/null | head -1)
    x_weekly_pct=$(printf '%s'    "$rl" | "$JQ" -r "$rlpick.secondary.used_percent // 0" 2>/dev/null | head -1)
    x_weekly_reset=$(printf '%s'  "$rl" | "$JQ" -r "$rlpick.secondary.resets_at    // 0" 2>/dev/null | head -1)
  fi
  tt=$(grep 'total_token_usage' "$newest" 2>/dev/null | tail -1)
  x_session_tokens=$(printf '%s' "$tt" | "$JQ" -r "$ttpick // 0" 2>/dev/null | head -1)
fi

ty=$(date +%Y/%m/%d)
sum=0
if [ -d "$SESS/$ty" ]; then
  while IFS= read -r f; do
    v=$(grep 'total_token_usage' "$f" 2>/dev/null | tail -1 | "$JQ" -r "$ttpick // 0" 2>/dev/null | head -1)
    v=${v%.*}; [ -n "$v" ] && sum=$((sum + v))
  done < <(find "$SESS/$ty" -name 'rollout-*.jsonl' 2>/dev/null)
fi
x_today_tokens=$sum

# ---------- emit ----------
cat <<EOF
{
  "claude": {
    "todayTokens": ${c_today_tokens:-0},
    "todayCost": ${c_today_cost:-0},
    "weekTokens": ${c_week_tokens:-0},
    "weekCost": ${c_week_cost:-0},
    "blockTokens": ${c_block_tokens:-0},
    "blockCost": ${c_block_cost:-0},
    "blockResetsAt": ${c_block_reset:-0}
  },
  "codex": {
    "primaryPercent": ${x_primary_pct:-0},
    "primaryResetsAt": ${x_primary_reset:-0},
    "weeklyPercent": ${x_weekly_pct:-0},
    "weeklyResetsAt": ${x_weekly_reset:-0},
    "sessionTokens": ${x_session_tokens:-0},
    "todayTokens": ${x_today_tokens:-0}
  }
}
EOF
