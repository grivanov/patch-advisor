#!/bin/bash
# Runs inside the nono sandbox, right before Claude Code starts (the compose command calls it with Claude Code's command line),
# and prints the settings in effect for this run. Then it replaces itself with that command.
# It only shows what the sandbox can see, so it cannot expose secrets: the real tokens never enter the sandbox.
set -u
WORK="${PA_WORK:-/work}"
INFO="$WORK/inventory/run-info.env"     # non-secret facts prepared by the wrapper (outside the sandbox)

get()  { sed -n "s/^$1=//p" "$INFO" 2>/dev/null | head -n1; }
line() { printf '  %-22s %s\n' "$1" "$2"; }
ago()  { # ago EPOCH -> "12 min" / "5 h" / "3 days"
  local s=$(( $(date +%s) - $1 ))
  if [ "$s" -lt 3600 ]; then echo "$(( s / 60 )) min"; elif [ "$s" -lt 172800 ]; then echo "$(( s / 3600 )) h"; else echo "$(( s / 86400 )) days"; fi
}

MODE="$(get MODE)"; PROFILE="$(get PROFILE)"; SERVER="$(hostname)"
echo "---- Run settings (inside the sandbox) ----"
line "Run" "$(get RUN_ID) · patch-advisor $(get VERSION) · server $SERVER"

if [ "$MODE" = outline ]; then
  url="$(jq -r '.mcpServers.outline.url // empty' "$WORK/.mcp.json" 2>/dev/null)"
  dest="Outline via MCP server \"outline\" (${url:-not configured})"
else
  dest="Markdown file in reports/$SERVER/"
fi
line "Mode / destination" "${MODE:-?} → $dest"
case "$PROFILE" in
  patch-advisor-apikey) auth="Console API key" ;;
  *)                    auth="subscription token" ;;
esac
line "Model / auth" "$(get MODEL) · profile ${PROFILE:-?} ($auth, injected by nono; Claude Code sees a placeholder)"
max="$(get MAX_SECONDS)"; line "Time limit" "$(( ${max:-360} / 60 )) min"

# Package lists: when the host last refreshed them (the inventory is only as fresh as they are)
lists="$(cat "$WORK/inventory/package-lists-updated.txt" 2>/dev/null)"
if t="$(date -d "$lists" +%s 2>/dev/null)" && [ -n "$lists" ]; then
  warn=""; [ $(( $(date +%s) - t )) -gt 172800 ] && warn="  ⚠ older than 2 days: the upgradable list may be stale"
  line "Package lists" "refreshed $(date -d "@$t" '+%Y-%m-%d %H:%M %Z') ($(ago "$t") ago)$warn"
else
  line "Package lists" "unknown (no package-lists-updated.txt)"
fi
upg="$(grep -c . "$WORK/inventory/packages-upgradable.txt" 2>/dev/null)"; inst="$(grep -c . "$WORK/inventory/packages-installed.tsv" 2>/dev/null)"
cont="$(grep -c . "$WORK/inventory/docker/containers.jsonl" 2>/dev/null)"
line "Inventory" "${upg:-0} upgradable of ${inst:-0} installed packages · ${cont:-0} running containers · $(sed -n 's/^PRETTY_NAME=//p' "$WORK/inventory/os-release" 2>/dev/null | tr -d '"') · kernel $(cat "$WORK/inventory/kernel.txt" 2>/dev/null)"

# Cache
if [ "$(get REFRESH)" = true ]; then
  line "Cache" "cleared for this run (full refresh requested)"
elif [ -d "$WORK/cache" ] && [ -n "$(ls -A "$WORK/cache" 2>/dev/null)" ]; then
  last="$(jq -r '.last_run // empty' "$WORK/cache/state.json" 2>/dev/null)"
  files="$(find "$WORK/cache" -type f | wc -l)"
  notes="$(find "$WORK/cache/notes" -type f 2>/dev/null | wc -l)"
  oldest="$(find "$WORK/cache" -type f -printf '%T@\n' 2>/dev/null | sort -n | head -n1 | cut -d. -f1)"
  euvd="$(find "$WORK/cache/euvd" -type f -printf '%T@\n' 2>/dev/null | sort -n | head -n1 | cut -d. -f1)"
  line "Cache" "in use · $files files · last run ${last:-?} · oldest entry ${oldest:+$(ago "$oldest") ago} · release-note summaries: $notes"
  if [ -n "$euvd" ]; then euvd_txt="$(ago "$euvd") old (refreshed after 1 day)"; else euvd_txt="not cached yet"; fi
  line "" "EUVD exploited list: $euvd_txt · entries expire after $(get CACHE_DAYS) days"
else
  line "Cache" "empty (first run, or expired): everything is fetched"
fi

# Network allowlist (from the nono profile the sandbox runs with)
prof="$HOME/.config/nono/profiles/${PROFILE:-patch-advisor}.json"
grep -q '"allow_domain"' "$prof" 2>/dev/null || prof="$HOME/.config/nono/profiles/patch-advisor.json"
doms="$(jq -r '.network.allow_domain[]? | if type == "string" then . else .domain end' "$prof" 2>/dev/null | paste -sd' ' -)"
line "Network allowlist" "$(printf '%s\n' "$doms" | wc -w) domains (+ the Claude Code profile's own): $doms"

line "Tools" "Claude Code $(claude --version 2>/dev/null | head -n1 | cut -d' ' -f1) · nono $(nono --version 2>/dev/null | head -n1 | awk '{print $NF}')"
line "Notifications" "$(get NOTIFY)"
line "Output" "$(get OUTPUT) · logs: $(get LOG)"
line "Last run" "$(get LAST_RUN)"
echo "--------------------------------------------"

exec "$@"
