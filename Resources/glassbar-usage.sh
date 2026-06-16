#!/bin/bash
# glassbar-usage.sh — emits Claude + Codex usage limits & totals as JSON, FAST (<1s).
#
# Fast/synchronous: Claude /usage limits (cached 5 min) + Codex rate-limits.
# Slow parts (ccusage daily/weekly cost, per-session token totals) are computed in
# the BACKGROUND into cache files and served from cache, so this script never blocks.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
export PATH
JQ=$(command -v jq || echo jq)
CC=$(command -v ccusage || true)
TODAY=$(date +%Y%m%d)
CACHE_DIR="$HOME/.cache/glassbar"; mkdir -p "$CACHE_DIR"
age() { echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0) )); }

# ---------------- Claude: /usage limits (cached 5 min) ----------------
CU='{}'; UF="$CACHE_DIR/claude-usage.json"
if [ -f "$UF" ] && [ "$(age "$UF")" -lt 300 ]; then
  CU=$(cat "$UF" 2>/dev/null)
else
  RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [ -n "$RAW" ]; then
    AT=$(printf '%s' "$RAW" | "$JQ" -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null); [ -z "$AT" ] && AT="$RAW"
    resp=$(curl -s --max-time 6 https://api.anthropic.com/api/oauth/usage \
          -H "Authorization: Bearer $AT" -H "anthropic-beta: oauth-2025-04-20" -H "Content-Type: application/json" 2>/dev/null)
    printf '%s' "$resp" | "$JQ" -e 'has("five_hour")' >/dev/null 2>&1 && { CU="$resp"; printf '%s' "$resp" > "$UF"; }
  fi
  [ "$CU" = '{}' ] && [ -f "$UF" ] && CU=$(cat "$UF" 2>/dev/null)
fi

# ---------------- Claude: ccusage cost (cached 120s, background refresh) ----------------
CCF="$CACHE_DIR/ccusage.json"
if [ -n "$CC" ] && { [ ! -f "$CCF" ] || [ "$(age "$CCF")" -ge 120 ]; }; then
  ( d=$("$CC" daily --json --since "$TODAY" --until "$TODAY" 2>/dev/null)
    w=$("$CC" weekly --json 2>/dev/null)
    tc=$(printf '%s' "$d" | "$JQ" -r '(.totals.totalCost // .daily[-1].totalCost // 0)' 2>/dev/null)
    tt=$(printf '%s' "$d" | "$JQ" -r '((.totals.totalTokens // .daily[-1].totalTokens // 0)|floor)' 2>/dev/null)
    wc=$(printf '%s' "$w" | "$JQ" -r '(.weekly[-1].totalCost // 0)' 2>/dev/null)
    wt=$(printf '%s' "$w" | "$JQ" -r '((.weekly[-1].totalTokens // 0)|floor)' 2>/dev/null)
    "$JQ" -n --argjson tc "${tc:-0}" --argjson tt "${tt:-0}" --argjson wc "${wc:-0}" --argjson wt "${wt:-0}" \
      '{todayCost:$tc,todayTokens:$tt,weekCost:$wc,weekTokens:$wt}' > "$CCF.tmp" 2>/dev/null && mv "$CCF.tmp" "$CCF"
  ) >/dev/null 2>&1 &
fi
CCDATA=$( [ -f "$CCF" ] && cat "$CCF" 2>/dev/null || echo '{}' )

# ---------------- Claude: per-session tokens (cached 60s, background refresh) ----------------
STF="$CACHE_DIR/session-tokens.json"
if [ ! -f "$STF" ] || [ "$(age "$STF")" -ge 60 ]; then
  ( ALL=$(find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null)
    OUT='{}'
    for f in "$HOME"/.claude/sessions/*.json; do
      [ -f "$f" ] || continue
      pid=$("$JQ" -r '.pid // empty' "$f" 2>/dev/null); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
      sid=$("$JQ" -r '.sessionId // empty' "$f" 2>/dev/null); [ -n "$sid" ] || continue
      tf=$(printf '%s\n' "$ALL" | grep "/$sid.jsonl$" | head -1); [ -n "$tf" ] || continue
      tok=$(grep -hoE '"(input_tokens|output_tokens)":[0-9]+' "$tf" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
      OUT=$(printf '%s' "$OUT" | "$JQ" -c --arg s "$sid" --argjson t "${tok:-0}" '. + {($s):$t}')
    done
    printf '%s' "$OUT" > "$STF.tmp" 2>/dev/null && mv "$STF.tmp" "$STF"
  ) >/dev/null 2>&1 &
fi
ST=$( [ -f "$STF" ] && cat "$STF" 2>/dev/null || echo '{}' )

# ---------------- Codex: limits + today tokens (fast) ----------------
x_pp=0; x_pr=0; x_wp=0; x_wr=0; x_today=0
SESS="$HOME/.codex/sessions"
newest=$(find "$SESS" -name 'rollout-*.jsonl' 2>/dev/null | sort | tail -1)
if [ -n "$newest" ]; then
  rl=$(grep 'rate_limits' "$newest" 2>/dev/null | tail -1)
  if [ -n "$rl" ]; then
    p='(.. | objects | select(has("rate_limits")) | .rate_limits)'
    x_pp=$(printf '%s' "$rl" | "$JQ" -r "$p.primary.used_percent   // 0" 2>/dev/null | head -1)
    x_pr=$(printf '%s' "$rl" | "$JQ" -r "$p.primary.resets_at      // 0" 2>/dev/null | head -1)
    x_wp=$(printf '%s' "$rl" | "$JQ" -r "$p.secondary.used_percent // 0" 2>/dev/null | head -1)
    x_wr=$(printf '%s' "$rl" | "$JQ" -r "$p.secondary.resets_at    // 0" 2>/dev/null | head -1)
  fi
fi
TDF="$CACHE_DIR/codex-today.json"
if [ ! -f "$TDF" ] || [ "$(age "$TDF")" -ge 120 ]; then
  ( ty=$(date +%Y/%m/%d); s=0
    if [ -d "$SESS/$ty" ]; then
      while IFS= read -r f; do
        v=$(grep 'total_token_usage' "$f" 2>/dev/null | tail -1 | "$JQ" -r '(.. | objects | select(has("total_token_usage")) | .total_token_usage.total_tokens) // 0' 2>/dev/null | head -1)
        v=${v%.*}; [ -n "$v" ] && s=$((s + v))
      done < <(find "$SESS/$ty" -name 'rollout-*.jsonl' 2>/dev/null)
    fi
    echo "$s" > "$TDF.tmp" && mv "$TDF.tmp" "$TDF"
  ) >/dev/null 2>&1 &
fi
x_today=$( [ -f "$TDF" ] && cat "$TDF" 2>/dev/null || echo 0 ); x_today=${x_today:-0}

# ---------------- assemble ----------------
"$JQ" -n --argjson cu "$CU" --argjson st "$ST" --argjson cc "$CCDATA" \
  --argjson xpp "${x_pp:-0}" --argjson xpr "${x_pr:-0}" --argjson xwp "${x_wp:-0}" --argjson xwr "${x_wr:-0}" --argjson xtd "${x_today:-0}" '
  def iso2epoch: if (type=="string" and length>=19) then ((.[0:19]+"Z")|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime) else 0 end;
  {
    claude: {
      ok: (if ($cu|has("five_hour")) then 1 else 0 end),
      fiveHourPercent:  ($cu.five_hour.utilization // 0),
      fiveHourResetsAt: (($cu.five_hour.resets_at // "") | iso2epoch),
      weekPercent:      ($cu.seven_day.utilization // 0),
      weekResetsAt:     (($cu.seven_day.resets_at // "") | iso2epoch),
      sonnetPercent:    ($cu.seven_day_sonnet.utilization // -1),
      opusPercent:      ($cu.seven_day_opus.utilization // -1),
      extraUsed:        ($cu.extra_usage.used_credits // 0),
      extraLimit:       ($cu.extra_usage.monthly_limit // 0),
      extraCurrency:    ($cu.extra_usage.currency // ""),
      todayCost: ($cc.todayCost // 0), todayTokens: ($cc.todayTokens // 0),
      weekCost: ($cc.weekCost // 0), weekTokens: ($cc.weekTokens // 0),
      sessionTokens: $st
    },
    codex: { primaryPercent: $xpp, primaryResetsAt: $xpr, weeklyPercent: $xwp, weeklyResetsAt: $xwr, todayTokens: $xtd }
  }'
