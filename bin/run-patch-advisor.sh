#!/usr/bin/env bash
# Entry point for xyOps (Shell Plugin via xySat, native or in Docker) or manual runs.
# Runs one patch audit on this host, keeps logs, and reports the result in xyOps Wire Protocol format.
set -uo pipefail

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"   # install location = parent of bin/ (any directory works)

# Load per-server settings from .env. A variable already set in the environment
# (e.g. an xyOps event parameter) is NOT overridden by .env.
if [ -r "$BASE/.env" ]; then
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue          # skip comments and blank lines
    # only patch-advisor's own settings: never PATH, LD_*, BASH_ENV etc. into this root script's environment
    [[ "$key" =~ ^(PATCH_ADVISOR_[A-Z_]+|OUTLINE_HOST|UBUNTU_VERSION|AUDIT_PROMPT|MAX_SECONDS|RUN_LOG_DAYS|ISSUES_[A-Z_]+|TRANSCRIPT_DAYS|CACHE_DAYS|NOTIFY_ON|NTFY_[A-Z_]+|WEBHOOK_[A-Z_]+)$ ]] || continue
    val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}"   # strip " # inline comment" and trailing spaces
    val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
    [ -z "${!key+x}" ] && export "$key=$val"
  done < "$BASE/.env"
fi
COMPOSE_FILE="${COMPOSE_FILE:-$BASE/patch-advisor.compose.yml}"
PA_VERSION="$(cat "$BASE/VERSION" 2>/dev/null || echo unknown)"
LOCK="${LOG_DIR:-$BASE/logs}/.run.lock"     # root-owned logs/ (never in data/, which UID 1000 can write); shared by xySat and host runs
MAX_SECONDS="${MAX_SECONDS:-360}"            # 6 minutes; a warm-cache run takes 1-2 minutes
LOG_DIR="${LOG_DIR:-$BASE/logs}"
RUN_LOG_DAYS="${RUN_LOG_DAYS:-30}"          # keep full per-run logs this long (gzipped after 1 day)
ISSUES_ROTATE_DAYS="${ISSUES_ROTATE_DAYS:-7}" # start a new issues.log after this many days...
ISSUES_MAX_MB="${ISSUES_MAX_MB:-50}"        # ...or when it reaches this size
ISSUES_KEEP="${ISSUES_KEEP:-26}"            # number of archived issues logs to keep
TRANSCRIPT_DAYS="${TRANSCRIPT_DAYS:-30}"    # keep Claude Code session transcripts this long
CACHE_DIR="$BASE/data/work/cache"           # agent's cache of fetched data (/work/cache in the container)
CACHE_DAYS="${CACHE_DAYS:-30}"              # cache files older than this are deleted
PATCH_ADVISOR_REFRESH="${PATCH_ADVISOR_REFRESH:-false}"   # true = clear the cache and fetch everything again
# Optional notifications after each run (sent by this script on the host, never by the agent)
# Reports (successful runs) go to NTFY_URL / WEBHOOK_URL; failed runs go to the *_FAILURE_* destinations
# (falling back to the report destinations if those are not set; set a *_FAILURE_URL to "none" to disable it).
NOTIFY_ON="${NOTIFY_ON:-always}"            # successful runs: always | findings (security/breaking/urgent > 0) | failure (none)
NTFY_URL="${NTFY_URL:-}"                    # e.g. https://ntfy.sh/my-topic or https://ntfy.example.com/patches
NTFY_TOKEN="${NTFY_TOKEN:-}"                # optional ntfy access token
WEBHOOK_URL="${WEBHOOK_URL:-}"              # generic JSON POST
WEBHOOK_AUTH_HEADER="${WEBHOOK_AUTH_HEADER:-}"  # optional, e.g. "Authorization: Bearer xyz"
NTFY_FAILURE_URL="${NTFY_FAILURE_URL:-$NTFY_URL}"
NTFY_FAILURE_TOKEN="${NTFY_FAILURE_TOKEN:-$NTFY_TOKEN}"
WEBHOOK_FAILURE_URL="${WEBHOOK_FAILURE_URL:-$WEBHOOK_URL}"
WEBHOOK_FAILURE_AUTH_HEADER="${WEBHOOK_FAILURE_AUTH_HEADER:-$WEBHOOK_AUTH_HEADER}"
# Server name used for the Outline documents and report paths (important when xySat runs in a container)
# Tools downloaded by `setup.sh --container-tools` (jq, docker-compose) are used only where the system has none,
# e.g. when this script runs inside a containerized xySat
export PATH="$PATH:$BASE/tools"
# The Compose command as a plain command (not a shell function), because it is also started through `timeout`
if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else COMPOSE=(); fi
export PATCH_ADVISOR_DIR="$BASE"   # used by the compose file for all paths; the real location always wins over .env
HOST="${PATCH_ADVISOR_HOST:-$(hostname)}"

# Optional xyOps event parameters (arrive as env vars); empty = use defaults from compose
export PATCH_ADVISOR_HOST="$HOST"
export AUDIT_PROMPT="${AUDIT_PROMPT:-}"
export PATCH_ADVISOR_PROFILE="${PATCH_ADVISOR_PROFILE:-patch-advisor}"
# Job type: outline = normal run, report saved to Outline; file = test run, report saved as Markdown file
export PATCH_ADVISOR_MODE="${PATCH_ADVISOR_MODE:-outline}"
# Claude model: alias (sonnet, opus) or a full model name
export PATCH_ADVISOR_MODEL="${PATCH_ADVISOR_MODEL:-sonnet}"
[ -z "$AUDIT_PROMPT" ] && unset AUDIT_PROMPT

mkdir -p "$LOG_DIR/runs" "$LOG_DIR/archive"
RUN_ID="$(date +%Y-%m-%d_%H%M%S)"
LOG="$LOG_DIR/runs/$RUN_ID.log"
ISSUES="$LOG_DIR/issues.log"

# Result output: "xyops" (default) prints xyOps wire-protocol JSON lines (job result, data, table, chart; other tools can
# parse or ignore them); "plain" prints one readable result line instead, e.g. for cron or systemd.
PATCH_ADVISOR_OUTPUT="${PATCH_ADVISOR_OUTPUT:-xyops}"
case "$PATCH_ADVISOR_OUTPUT" in xyops|plain) ;; *) PATCH_ADVISOR_OUTPUT=xyops ;; esac
xy() { # code, description, extra JSON for "data"
  if [ "$PATCH_ADVISOR_OUTPUT" = plain ]; then
    printf 'Result: exit code %s: %s\n' "$1" "$2"
  else
    printf '{"xy":1,"code":%s,"description":%s,"data":%s}\n' \
      "$1" "$(printf '%s' "$2" | jq -Rs .)" "${3:-{\}}"
  fi
}
# One line per problem: timestamp, run id, level, message (rotated by rotate_issues below)
issue() { printf '%s %s %s %s\n' "$(date -Is)" "$RUN_ID" "$1" "$2" >> "$ISSUES"; }

case "$PATCH_ADVISOR_MODE" in
  outline|file) ;;
  *) xy 1 "Unknown PATCH_ADVISOR_MODE '$PATCH_ADVISOR_MODE' (use outline or file)."; exit 1 ;;
esac
# Only the two shipped sandbox profiles may be used: any other nono profile (e.g. the built-in, less strict
# claude-code profile) would bypass the command policies and network rules.
case "$PATCH_ADVISOR_PROFILE" in
  patch-advisor|patch-advisor-apikey) ;;
  *) xy 1 "Unknown PATCH_ADVISOR_PROFILE '$PATCH_ADVISOR_PROFILE' (use patch-advisor or patch-advisor-apikey)."; exit 1 ;;
esac
if ! [[ "$PATCH_ADVISOR_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  xy 1 "Invalid PATCH_ADVISOR_MODEL '$PATCH_ADVISOR_MODEL'."; exit 1
fi
# The server name becomes the container hostname and is used to find documents: keep it a valid hostname
if ! [[ "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,62})$ ]]; then
  xy 1 "Invalid PATCH_ADVISOR_HOST '$HOST' (letters, digits, dots and dashes only)."; exit 1
fi
# Numeric settings (from .env or event parameters): fall back to the default if not a plain number
num() { local v="${!1}"; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] || printf -v "$1" '%s' "$2"; }
num MAX_SECONDS 360; num RUN_LOG_DAYS 30; num ISSUES_ROTATE_DAYS 7; num ISSUES_MAX_MB 50; num ISSUES_KEEP 26
num TRANSCRIPT_DAYS 30; num CACHE_DAYS 30
# Outline origin (scheme + host), used to validate the report URLs the agent returns
OUTLINE_ORIGIN="$(jq -r '.mcpServers.outline.url // ""' "$BASE/config/claude/mcp.json" 2>/dev/null | grep -oE '^https://[^/]+' || true)"
mkdir -p "$BASE/reports" && chown 1000:1000 "$BASE/reports" 2>/dev/null

# data/ itself stays root-owned; only its subdirectories belong to the container user (UID 1000). UID 1000 is the agent,
# and on many hosts also the first human user. Root must never follow a symlink that UID 1000 planted below data/ or reports/.
mkdir -p "$BASE/data/home" "$BASE/data/work"
chown root:root "$BASE/data" && chmod 755 "$BASE/data"
safe_under() { # safe_under PATH DIR: PATH is not a symlink and its real parent directory is inside DIR
  local parent
  [ -L "$1" ] && return 1
  parent="$(realpath -e "$(dirname "$1")" 2>/dev/null)" || return 1
  [[ "$parent/" == "$(realpath -e "$2")/"* ]]
}

# Secrets edited with an editor often end with a newline (nano adds one by default), which would become part of
# the token: strip trailing newlines/carriage returns in place (owner and mode are kept)
for f in "$BASE/secrets/anthropic_credential" "$BASE/secrets/outline_token"; do
  if [ -s "$f" ] && [ "$(tail -c1 "$f" | od -An -tx1 | tr -d ' \n')" = 0a ]; then
    t="$(cat "$f")"; t="${t%$'\r'}"; printf '%s' "$t" > "$f"
  fi
done

# Preflight: fail early with a clear message instead of a Docker mount error and an empty run summary
PREFLIGHT=()
for f in anthropic_credential outline_token; do
  if [ ! -s "$BASE/secrets/$f" ]; then
    PREFLIGHT+=("missing or empty secret $BASE/secrets/$f (run bin/setup.sh, then put the real token in)")
  elif grep -q '^REPLACE_ME' "$BASE/secrets/$f" && { [ "$f" = anthropic_credential ] || [ "$PATCH_ADVISOR_MODE" = outline ]; }; then
    PREFLIGHT+=("secret $BASE/secrets/$f is still the setup placeholder: put the real token in (README, \"Tokens\")")
  fi
done
# The nono profiles extend "claude-code", which comes from the registry pack nolabs-ai/claude (installed once per server)
grep -qs '"[^"]*/claude' "$BASE/data/home/.config/nono/packages/lockfile.json" \
  || PREFLIGHT+=("nono pack nolabs-ai/claude not installed: run once: docker compose -f $COMPOSE_FILE run --rm -T patch-advisor nono pull nolabs-ai/claude </dev/null")
[ "${#COMPOSE[@]}" -gt 0 ] || PREFLIGHT+=("Docker Compose not found (neither 'docker compose' nor docker-compose): install the plugin, or run setup.sh --container-tools")
docker image inspect patch-advisor:latest >/dev/null 2>&1 \
  || PREFLIGHT+=("image patch-advisor:latest not found: build it first with: docker compose -f $COMPOSE_FILE build")
if [ "${#PREFLIGHT[@]}" -gt 0 ]; then
  for m in "${PREFLIGHT[@]}"; do echo "Preflight: $m"; issue ERROR "Preflight: $m"; done
  xy 1 "Preflight failed on $HOST: ${PREFLIGHT[0]}$([ "${#PREFLIGHT[@]}" -gt 1 ] && echo " (+$(( ${#PREFLIGHT[@]} - 1 )) more, see job log)")"
  exit 1
fi

# One audit per host at a time
exec 9>"$LOCK"
if ! flock -n 9; then
  issue ERROR "Skipped: another run is already in progress."
  xy 1 "Another patch-advisor run is already in progress on $HOST."
  exit 1
fi

# Housekeeping (all under $BASE, no system logrotate needed)
rotate_issues() {
  [ -s "$ISSUES" ] || return 0
  local first now age size arch
  first="$(head -c 10 "$ISSUES")"                       # YYYY-MM-DD of the oldest entry
  now="$(date +%s)"
  age=$(( (now - $(date -d "$first" +%s 2>/dev/null || echo "$now")) / 86400 ))
  size="$(stat -c %s "$ISSUES")"
  if [ "$age" -ge "$ISSUES_ROTATE_DAYS" ] || [ "$size" -ge $(( ISSUES_MAX_MB * 1024 * 1024 )) ]; then
    arch="$LOG_DIR/archive/issues-$(date +%Y-%m-%d_%H%M%S).log"
    mv "$ISSUES" "$arch" && gzip -9 "$arch"
  fi
  ls -1t "$LOG_DIR"/archive/issues-*.log.gz 2>/dev/null | tail -n +"$((ISSUES_KEEP + 1))" | xargs -r rm -f
}
rotate_issues
find "$LOG_DIR/runs" \( -name '*.log' -o -name '*.jsonl' \) -mtime +0 -exec gzip -9 {} + 2>/dev/null
find "$LOG_DIR/runs" -name '*.gz' -mtime +"$RUN_LOG_DAYS" -delete 2>/dev/null
find "$BASE/data/home/.claude/projects" -type f -mtime +"$TRANSCRIPT_DAYS" -delete 2>/dev/null
case "$PATCH_ADVISOR_REFRESH" in
  true|1|yes) rm -rf "$CACHE_DIR"; echo "Cache cleared (PATCH_ADVISOR_REFRESH)";;
  *) find "$CACHE_DIR" -type f -mtime +"$CACHE_DAYS" -delete 2>/dev/null;;
esac

# Claude Code ignores a project's .claude/settings.json (our permission allowlist) until the folder is "trusted".
# Headless runs cannot answer that prompt, so mark /work as trusted in Claude Code's config. Safe here: everything
# Claude Code reads from /work as project config (CLAUDE.md, settings.json, .mcp.json) is our own read-only mount.
CC_DIR="$BASE/data/home/.claude"; CC_JSON="$CC_DIR/.claude.json"
[ -e "$CC_DIR" ] || [ -L "$CC_DIR" ] || { mkdir "$CC_DIR" && chown 1000:1000 "$CC_DIR"; }
if safe_under "$CC_JSON" "$BASE/data/home" && [ -d "$CC_DIR" ] && [ ! -L "$CC_DIR" ] && { [ ! -e "$CC_JSON" ] || [ -f "$CC_JSON" ]; }; then
  tmp="$(mktemp "$CC_DIR/.claude.json.XXXXXX")"     # new file, created exclusively: nothing planted can be followed
  if [ -s "$CC_JSON" ]; then
    jq '.projects["/work"].hasTrustDialogAccepted = true' "$CC_JSON" > "$tmp" \
      || { printf '%s\n' '{"projects":{"/work":{"hasTrustDialogAccepted":true}}}' > "$tmp"; issue WARN "$CC_JSON was not valid JSON; replaced with a minimal one."; }
  else
    printf '%s\n' '{"projects":{"/work":{"hasTrustDialogAccepted":true}}}' > "$tmp"
  fi
  chown 1000:1000 "$tmp" && chmod 600 "$tmp" && mv -fT "$tmp" "$CC_JSON"   # rename replaces the entry itself, never a link target
else
  issue ERROR "Refusing to update $CC_JSON: it (or its directory) is a symlink or not a regular file. Remove it; Claude Code may ignore settings.json until then."
fi

# Claude Code's temp dir (CLAUDE_CODE_TMPDIR=/work/.tmp in the container): start every run with an empty one
rm -rf "$BASE/data/work/.tmp" && mkdir -p "$BASE/data/work/.tmp" && chown 1000:1000 "$BASE/data/work/.tmp"

RUN_NAME=patch-advisor-run
# If the job is killed or times out, the compose CLI dies but the container may keep running: remove it explicitly.
PIPE_PID=""
cleanup() { docker rm -f "$RUN_NAME" >/dev/null 2>&1; rm -f "${RC_FILE:-}"; }
trap cleanup EXIT
# Abort (xyOps "abort job", SIGTERM/SIGINT): stop the run immediately. The pipeline runs in the background
# and we wait for it, because bash would otherwise delay the trap until the whole pipeline finished.
on_abort() {
  issue ERROR "Run aborted (signal)."
  docker rm -f "$RUN_NAME" >/dev/null 2>&1
  if [ -n "$PIPE_PID" ]; then
    pkill -TERM -P "$PIPE_PID" 2>/dev/null   # timeout, docker compose, tee, jq
    kill "$PIPE_PID" 2>/dev/null
  fi
  xy 1 "Audit aborted on $HOST."
  exit 143
}
trap on_abort INT TERM
docker rm -f "$RUN_NAME" >/dev/null 2>&1   # leftover from a crashed run

# Readable log from Claude Code's stream-json output: assistant text and tool calls; other lines pass through unchanged.
# Every line that starts with "{" is prefixed with "» ": with JSON parsing enabled, xyOps would otherwise treat
# agent-written JSON as protocol messages (job result, data, even actions). Only this script may speak to xyOps.
READABLE='. as $line | (try fromjson catch null) as $e
  | if ($e | type) != "object" then $line
    elif $e.type == "system" and $e.subtype == "init" then "[claude] started, model \($e.model // "?")"
    elif $e.type == "assistant" then
      ($e.message.content[]? |
        if .type == "text" then .text
        elif .type == "tool_use" then "[tool] \(.name): \((.input.command // .input.url // .input.file_path // (.input | tostring)) | tostring | .[0:200])"
        else empty end)
    elif $e.type == "result" then "[claude] finished: \($e.subtype // "?"), \($e.num_turns // 0) turns"
    else empty end
  | split("\n")[]
  | if test("^\\s*\\{") then "» " + . else . end'

RAW="$LOG_DIR/runs/$RUN_ID.jsonl"   # full event stream (every message, tool call and tool result)
STATS_FILE="$LOG_DIR/stats.jsonl"    # one line of statistics per run
START_TS="$(date +%s)"

echo "Starting patch-advisor $PA_VERSION audit on $HOST, mode $PATCH_ADVISOR_MODE, model $PATCH_ADVISOR_MODEL, profile $PATCH_ADVISOR_PROFILE (log: $LOG)"

# ---- Inventory: collected here, on the trusted side, with fixed commands. The agent only reads the result
# (mounted read-only as /work/inventory) and has no access to apt, dpkg or Docker itself.
INV="$BASE/data/inventory"
rm -rf "$INV" && mkdir -p "$INV/docker" && chown -R 1000:1000 "$INV"
# 1) OS and packages: short-lived container without network, host package data read-only
if ! "${COMPOSE[@]}" -f "$COMPOSE_FILE" run --rm -T --name patch-advisor-inventory inventory </dev/null >"$INV/collector.log" 2>&1; then
  issue WARN "Package inventory incomplete; see $INV/collector.log"
  echo "Package inventory incomplete:"; sed 's/^/  | /' "$INV/collector.log" | tail -n 5
fi
# 2) Containers and images: version-relevant fields only. No container environment variables or command lines:
#    those often contain passwords. Image environment is reduced to version-like variables.
collect_docker() {
  local d="$INV/docker" ids imgs i
  ids="$(docker ps -q --no-trunc)" || return 1
  docker ps --no-trunc --format '{{json .}}' \
    | jq -c '{name: .Names, image: .Image, state: .State, status: .Status, created: .CreatedAt}' > "$d/containers.jsonl" || return 1
  [ -n "$ids" ] || { echo '[]' > "$d/images.json"; return 0; }
  # container name -> image ID (added to containers.jsonl)
  docker inspect --format '{{.Name}} {{.Image}}' $ids | sed 's#^/##' > "$d/.image-ids" || return 1
  jq -c --rawfile map "$d/.image-ids" '
      ($map | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add) as $m
      | . + {image_id: $m[.name]}' "$d/containers.jsonl" > "$d/.c" && mv "$d/.c" "$d/containers.jsonl"
  imgs="$(cut -d' ' -f2 "$d/.image-ids" | sort -u)"; rm -f "$d/.image-ids"
  docker image inspect $imgs | jq '[.[] | {id: .Id, repo_tags: .RepoTags, repo_digests: .RepoDigests, created: .Created,
      architecture: .Architecture, labels: .Config.Labels,
      VersionEnv: [(.Config.Env // [])[] | select(test("(VERSION|_MAJOR|_MINOR|_RELEASE|_REVISION)="))]}]' > "$d/images.json" || return 1
  for i in $imgs; do
    docker image history --no-trunc --format '{{.CreatedBy}}' "$i" 2>/dev/null \
      | grep -iE 'version|_major|release|download|curl|wget|\.tar|\.tgz' \
      | sed -E 's/([A-Za-z_]*(TOKEN|PASSWORD|PASSWD|SECRET|API_?KEY|AUTH)[A-Za-z_]*=)[^ ]+/\1[redacted]/Ig; s/((bearer|basic|token) +)[^ "'"'"']+/\1[redacted]/Ig; s/((authorization|token|password|passwd|secret)[:=] *)([^ "'"'"'[][^ "'"'"']*)/\1[redacted]/Ig; s#(https?://)[^/@ ]+@#\1[redacted]@#g' \
      | cut -c1-300 | head -n 40 > "$d/history-${i#sha256:}.txt"
  done
}
if ! collect_docker 2>"$INV/docker/collect.err"; then
  issue WARN "Docker inventory incomplete; see $INV/docker/collect.err"
else
  [ -s "$INV/docker/collect.err" ] || rm -f "$INV/docker/collect.err"
fi
# Non-secret facts for the run-settings summary that bin/run-summary.sh prints inside the sandbox (things the sandbox
# cannot see itself). Notification targets are reduced to host names: ntfy topics and webhook paths often act as passwords.
host_of() { printf '%s' "$1" | sed -E 's#^[A-Za-z]+://([^/@]*@)?([^/:?#]+).*#\2#'; }
notify_desc() {
  local d=""
  [ -n "$NTFY_URL" ] && d="ntfy → $(host_of "$NTFY_URL")"
  [ -n "$WEBHOOK_URL" ] && d="${d:+$d, }webhook → $(host_of "$WEBHOOK_URL")"
  if [ "$NTFY_FAILURE_URL$WEBHOOK_FAILURE_URL" != "$NTFY_URL$WEBHOOK_URL" ]; then
    local f=""
    [ -n "$NTFY_FAILURE_URL" ] && [ "$NTFY_FAILURE_URL" != none ] && f="ntfy → $(host_of "$NTFY_FAILURE_URL")"
    [ -n "$WEBHOOK_FAILURE_URL" ] && [ "$WEBHOOK_FAILURE_URL" != none ] && f="${f:+$f, }webhook → $(host_of "$WEBHOOK_FAILURE_URL")"
    d="${d:-none}; failures: ${f:-none}"
  fi
  printf '%s (reports: NOTIFY_ON=%s)' "${d:-none}" "$NOTIFY_ON"
}
LAST_RUN="$(tail -n1 "$LOG_DIR/stats.jsonl" 2>/dev/null | jq -r '"\(.run_id) · exit \(.rc) · \(.security // "?") security, \(.breaking // "?") breaking, \(.urgent // "?") urgent, \(.routine // "?") routine · saved: \(.saved)"' 2>/dev/null)"
{
  printf 'RUN_ID=%s\nVERSION=%s\nMODE=%s\nMODEL=%s\nPROFILE=%s\nMAX_SECONDS=%s\nREFRESH=%s\nCACHE_DAYS=%s\n' \
    "$RUN_ID" "$PA_VERSION" "$PATCH_ADVISOR_MODE" "$PATCH_ADVISOR_MODEL" "$PATCH_ADVISOR_PROFILE" "$MAX_SECONDS" "$PATCH_ADVISOR_REFRESH" "$CACHE_DAYS"
  printf 'OUTPUT=%s\nLOG=%s\nNOTIFY=%s\nLAST_RUN=%s\n' "$PATCH_ADVISOR_OUTPUT" "$LOG" "$(notify_desc)" "${LAST_RUN:-none}"
} > "$INV/run-info.env"
chown -R 1000:1000 "$INV"
echo "Inventory: $(wc -l < "$INV/packages-installed.tsv" 2>/dev/null || echo 0) packages installed, $(wc -l < "$INV/packages-upgradable.txt" 2>/dev/null || echo 0) upgradable, $(wc -l < "$INV/docker/containers.jsonl" 2>/dev/null || echo 0) containers"
RC_FILE="$(mktemp)"
# stdin is closed (</dev/null): xyOps passes the job document on STDIN, and `claude -p` would append
# anything it reads from stdin to the prompt.
(
  timeout --kill-after=60 "$MAX_SECONDS" \
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" run --rm -T --name "$RUN_NAME" patch-advisor </dev/null 2>&1 \
    | tee "$RAW" | jq -R -r --unbuffered "$READABLE" | tee "$LOG"
  echo "${PIPESTATUS[0]}" > "$RC_FILE"
) 9>&- &      # 9>&-: the run's processes must not inherit (and keep holding) the run lock
PIPE_PID=$!
wait "$PIPE_PID"
RC="$(cat "$RC_FILE" 2>/dev/null)"; RC="${RC:-1}"
WALL_S=$(( $(date +%s) - START_TS ))

# Problems reported by Claude itself (lines starting with "ISSUE ")
grep -E '^[`*[:space:]]*ISSUE ' "$LOG" | sed -E 's/^[`*[:space:]]*ISSUE //; s/[`*]+$//' \
  | grep -viE '(^|:)[[:space:]]*(none|n/a|nothing)[.[:space:]]*$' \
  | while IFS= read -r line; do issue WARN "$line"; done   # "ISSUE ...: none" is not an issue
# Commands blocked by the nono sandbox
DENIED="$(grep -ciE 'command policy denied|permission denied by nono|nono: .*denied' "$RAW")"
[ "$DENIED" -gt 0 ] && issue WARN "nono blocked $DENIED action(s); see $RAW and 'nono audit show'."

# Claude ends with: RESULT security=N breaking=N urgent=N routine=N saved=ok|failed [file=<path>]
RESULT="$(grep -E '^[`*[:space:]]*RESULT ' "$LOG" | tail -n1 | sed -E 's/^[`*[:space:]]+//; s/[`*[:space:]]+$//')"
get() { printf ' %s' "$RESULT" | grep -oE " $1=[^ ]+" | head -n1 | cut -d= -f2-; }
SEC="$(get security)"; BRK="$(get breaking)"; URG="$(get urgent)"; ROU="$(get routine)"; OUT="$(get saved)"; RFILE="$(get file)"; DOC_URL="$(get url)"; SUM_URL="$(get summary_url)"; COMPLETE="$(get complete)"
# The RESULT line is written by the agent: accept only what we expect
SEC="${SEC//[^0-9]/}"; BRK="${BRK//[^0-9]/}"; URG="${URG//[^0-9]/}"; ROU="${ROU//[^0-9]/}"
case "$OUT" in ok|failed) ;; *) OUT="" ;; esac
case "$COMPLETE" in yes|no) ;; *) COMPLETE="" ;; esac
valid_outline_url() {   # must point into our own Outline instance; no characters that could break headers/ntfy actions
  local re='^[A-Za-z0-9:/._~%#?=&+-]+$'
  [ -n "$1" ] && [ -n "$OUTLINE_ORIGIN" ] && [[ "$1" == "$OUTLINE_ORIGIN"/* ]] && [[ "$1" =~ $re ]]
}
for v in DOC_URL SUM_URL; do
  if [ -n "${!v}" ] && ! valid_outline_url "${!v}"; then
    issue WARN "Ignored report URL that is not in the configured Outline instance: ${!v}"; printf -v "$v" '%s' ""
  fi
done
# Outline URLs: remember the last valid ones (documents keep their address), and fall back to them when a run
# saved to Outline without returning a URL (e.g. after only updating existing documents). Stored in root-owned logs/.
URL_STATE="$LOG_DIR/.outline-urls"
if [ "$PATCH_ADVISOR_MODE" = outline ] && [ "$OUT" = ok ]; then
  if [ -n "$DOC_URL" ] || [ -n "$SUM_URL" ]; then
    LAST_DOC="$(sed -n 's/^url=//p' "$URL_STATE" 2>/dev/null)"; LAST_SUM="$(sed -n 's/^summary_url=//p' "$URL_STATE" 2>/dev/null)"
    printf 'url=%s\nsummary_url=%s\n' "${DOC_URL:-$LAST_DOC}" "${SUM_URL:-$LAST_SUM}" > "$URL_STATE"
  fi
  for v in DOC_URL SUM_URL; do
    if [ -z "${!v}" ]; then
      key=url; [ "$v" = SUM_URL ] && key=summary_url
      last="$(sed -n "s/^$key=//p" "$URL_STATE" 2>/dev/null)"
      if [ -n "$last" ] && valid_outline_url "$last"; then
        printf -v "$v" '%s' "$last"; issue WARN "Claude returned no $key; using the last known one: $last"
      fi
    fi
  done
fi
# Path of the report file on the host (container /work/reports = $BASE/reports)
if [ -n "$RFILE" ]; then
  if [[ "$RFILE" =~ ^/work/reports/[A-Za-z0-9._/-]+\.md$ && "$RFILE" != *..* ]]; then
    RFILE="$BASE/reports/${RFILE#/work/reports/}"
    # only a regular file that was actually written, really inside reports/ (no symlink planted by UID 1000)
    if [ -L "$RFILE" ] || [ ! -f "$RFILE" ] || ! safe_under "$RFILE" "$BASE/reports"; then
      [ -e "$RFILE" ] || [ -L "$RFILE" ] && issue WARN "Ignored report file that is a symlink or outside reports/: $RFILE"
      RFILE=""
    fi
  else
    issue WARN "Ignored invalid report file path: $RFILE"; RFILE=""
  fi
fi

# Safety net: a report written as one line with literal "\n" sequences instead of real line breaks
if [ -n "$RFILE" ] && [ -f "$RFILE" ] && [ "$(wc -l < "$RFILE")" -lt 5 ] && grep -q '\\n' "$RFILE"; then
  sed -i 's/\\n/\n/g' "$RFILE"
  issue WARN "Report contained literal \\n instead of line breaks; converted: $RFILE"
fi

# Exact inventory totals, counted here (not by the agent): upgradable OS packages and running containers
UPG_PKGS="$(grep -c . "$INV/packages-upgradable.txt" 2>/dev/null)"; UPG_PKGS="${UPG_PKGS:-0}"   # grep -c prints 0 itself (and exits 1)
N_CONT="$(grep -c . "$INV/docker/containers.jsonl" 2>/dev/null)"; N_CONT="${N_CONT:-0}"

# Run statistics from Claude Code's final "result" event (duration, turns, tokens, cost)
CLAUDE_RESULT="$(jq -R -c 'try fromjson catch empty | select(type == "object" and .type == "result")' "$RAW" 2>/dev/null | tail -n1)"
[ -n "$CLAUDE_RESULT" ] || CLAUDE_RESULT='{}'
STATS="$(jq -c --argjson wall "$WALL_S" '{
    wall_s: $wall,
    claude_s: (((.duration_ms // 0) / 1000) | floor),
    api_s: (((.duration_api_ms // 0) / 1000) | floor),
    turns: (.num_turns // 0),
    input_tokens: (.usage.input_tokens // 0),
    output_tokens: (.usage.output_tokens // 0),
    cache_read_tokens: (.usage.cache_read_input_tokens // 0),
    cache_write_tokens: (.usage.cache_creation_input_tokens // 0),
    cost_usd: ((.total_cost_usd // 0) * 10000 | round / 10000),
    models: ((.modelUsage // {}) | keys),
    denied_tool_calls: ((.permission_denials // []) | length),
    claude_status: (.subtype // "none")
  } | .total_tokens = (.input_tokens + .output_tokens + .cache_read_tokens + .cache_write_tokens)' <<<"$CLAUDE_RESULT")"
DATA="$(jq -c -n --arg h "$HOST" --arg s "${SEC:-}" --arg b "${BRK:-}" --arg u "${URG:-}" --arg r "${ROU:-}" --arg o "${OUT:-}" \
  --arg l "$LOG" --arg raw "$RAW" --arg m "$PATCH_ADVISOR_MODE" --arg md "$PATCH_ADVISOR_MODEL" --arg f "${RFILE:-}" --arg du "${DOC_URL:-}" --arg su "${SUM_URL:-}" --arg c "${COMPLETE:-}" --arg ver "$PA_VERSION" --argjson upg "${UPG_PKGS:-0}" --argjson nc "${N_CONT:-0}" --argjson st "$STATS" --argjson rc "$RC" \
  '{host:$h, security:($s|tonumber? // null), breaking:($b|tonumber? // null), urgent:($u|tonumber? // null), routine:($r|tonumber? // null),
    version:$ver, upgradable_packages:$upg, containers:$nc, mode:$m, model:$md, saved:$o, complete:$c, report_file:$f, outline_url:$du, outline_summary_url:$su, log:$l, event_log:$raw, rc:$rc} + $st')"

DENIED_CALLS="$(jq -r '.denied_tool_calls' <<<"$STATS")"
[ "$DENIED_CALLS" -gt 0 ] && issue WARN "Claude Code refused $DENIED_CALLS tool call(s) by its permission settings; see $RAW."

# Human-readable summary (job log + run log), stats history, and xyOps table / perf chart
SUMMARY_TXT="$(jq -r '
  def dur: (. / 3600 | floor) as $h | ((. % 3600) / 60 | floor) as $m | (. % 60) as $s
    | if $h > 0 then "\($h)h \($m)m \($s)s" elif $m > 0 then "\($m)m \($s)s" else "\($s)s" end;
  def k: if . >= 1000000 then "\(. / 100000 | floor / 10)M" elif . >= 1000 then "\(. / 100 | floor / 10)k" else "\(.)" end;
  "---- Run summary ----",
  "Version:              patch-advisor \(.version)",
  "Host / mode / model:  \(.host) / \(.mode) / \(.model) \(if (.models | length) > 0 then "(" + (.models | join(", ")) + ")" else "" end)",
  "Duration:             \(.wall_s | dur) total (Claude \(.claude_s | dur), of which model API \(.api_s | dur))",
  "Turns:                \(.turns)",
  "Tokens:               \(.total_tokens | k) total: input \(.input_tokens | k), output \(.output_tokens | k), cache read \(.cache_read_tokens | k), cache write \(.cache_write_tokens | k)",
  "Cost:                 $\(.cost_usd) (estimated by Claude Code; with a subscription token usage counts against plan limits, not billed per token)",
  "Inventory:            \(.upgradable_packages) upgradable OS packages, \(.containers) running containers (the findings below count items, which group related packages)",
  "Findings:             \(.security // "?") security, \(.breaking // "?") breaking, \(.urgent // "?") urgent, \(.routine // "?") routine; complete: \(if .complete == "" then "?" else .complete end); saved: \(.saved)",
  "Denied tool calls:    \(.denied_tool_calls)",
  (if .outline_url != "" then "Outline:              \(.outline_url)\(if .outline_summary_url != "" then "  (summary: " + .outline_summary_url + ")" else "" end)" elif .report_file != "" then "Report file:          \(.report_file)" else empty end),
  "Logs:                 \(.log) (readable), \(.event_log) (full)"' <<<"$DATA")"
printf '\n%s\n' "$SUMMARY_TXT" | tee -a "$LOG"
jq -c --arg run "$RUN_ID" '{run_id:$run} + .' <<<"$DATA" >> "$STATS_FILE"

[ "$PATCH_ADVISOR_OUTPUT" = xyops ] && jq -c '{xy:1, table:{title:"Run summary", header:["Metric","Value"], rows:[
    ["Server", .host], ["Mode", .mode], ["Model", (if (.models | length) > 0 then (.models | join(", ")) else .model end)],
    ["Duration (total)", "\(.wall_s) s"], ["Claude", "\(.claude_s) s"], ["Model API", "\(.api_s) s"], ["Turns", .turns],
    ["Input tokens", .input_tokens], ["Output tokens", .output_tokens], ["Cache read tokens", .cache_read_tokens], ["Cache write tokens", .cache_write_tokens],
    ["Total tokens", .total_tokens], ["Estimated cost (USD)", .cost_usd],
    ["Security / Breaking / Urgent / Routine", "\(.security // "?") / \(.breaking // "?") / \(.urgent // "?") / \(.routine // "?")"],
    ["Upgradable OS packages / containers", "\(.upgradable_packages) / \(.containers)"],
    ["Denied tool calls", .denied_tool_calls],
    ["Report", (if .outline_url != "" then .outline_url elif .report_file != "" then .report_file else "-" end)]]}}' <<<"$DATA"
[ "$PATCH_ADVISOR_OUTPUT" = xyops ] && jq -c '{xy:1, perf:{"Model API": .api_s, "Tools and processing": ([.claude_s - .api_s, 0] | max), "Container start/stop": ([.wall_s - .claude_s, 0] | max)}}' <<<"$DATA"

DUR_TOK="$(jq -r 'def k: if . >= 1000000 then "\(. / 100000 | floor / 10)M" elif . >= 1000 then "\(. / 100 | floor / 10)k" else "\(.)" end;
  "\(.wall_s / 60 | floor)m \(.wall_s % 60)s, \(.total_tokens | k) tokens"' <<<"$DATA")"

# Exit codes: 0 = done, 1 = run failed, 2 = report not saved, 3 = audit incomplete (partial report saved).
# The container's own exit code is in data.rc.
if [ "$RC" -eq 124 ] || { [ "$RC" -eq 137 ] && [ "$WALL_S" -ge "$MAX_SECONDS" ]; }; then
  CODE=1; DESC="Audit timed out after ${MAX_SECONDS}s ($DUR_TOK)."
  issue ERROR "Timed out after ${MAX_SECONDS}s."
elif [ "$RC" -eq 137 ]; then
  CODE=1; DESC="Audit container was killed (exit 137, most likely out of memory; $DUR_TOK)."
  issue ERROR "Container killed (exit 137), most likely out of memory: raise mem_limit."
elif LIMIT_MSG="$(grep -m1 -oiE "(you've )?hit your [a-z ]*limit[^\"]*|usage limit reached[^\"]*" "$LOG")"; [ -n "$LIMIT_MSG" ] && [ -z "$RESULT" ]; then
  CODE=1; DESC="Claude usage limit reached: $LIMIT_MSG. Nothing was audited; rerun after the reset ($DUR_TOK)."
  issue ERROR "Claude usage limit reached: $LIMIT_MSG"
elif [ "$RC" -ne 0 ]; then
  CODE=1; DESC="Audit failed (exit $RC, $DUR_TOK). See job log."
  issue ERROR "Failed with exit code $RC."
elif [ -z "$RESULT" ]; then
  CODE=1; DESC="Audit finished but produced no RESULT line ($DUR_TOK)."
  issue ERROR "Finished without a RESULT line."
elif [ "$OUT" != "ok" ]; then
  CODE=2; DESC="Audit done, but saving the report ($PATCH_ADVISOR_MODE) failed. Report is in the job log${RFILE:+ and in $RFILE} ($DUR_TOK)."
  issue ERROR "Saving the report ($PATCH_ADVISOR_MODE) failed; report is in $LOG."
elif [ "$COMPLETE" != "yes" ]; then
  if [ "$PATCH_ADVISOR_MODE" = file ]; then WHERE="saved to ${RFILE:-$BASE/reports}"; else WHERE="saved to Outline"; fi
  CODE=3; DESC="$HOST: audit INCOMPLETE (see ISSUE lines in the job log); partial report $WHERE ($DUR_TOK)."
  issue ERROR "Audit incomplete: some inventories or checks could not be done; the counts are not reliable."
else
  CODE=0
  if [ "$PATCH_ADVISOR_MODE" = file ]; then WHERE="Saved to ${RFILE:-$BASE/reports}"; else WHERE="Saved to Outline"; fi
  DESC="$HOST: ${SEC} security, ${BRK} breaking, ${URG} urgent, ${ROU} routine. $WHERE. ($DUR_TOK)"
fi

# ---- Optional notifications (ntfy and/or generic webhook) ----
notify() {
  local ntfy_url ntfy_token hook_url hook_auth kind
  if [ "$CODE" -ne 0 ]; then
    kind=failure; ntfy_url="$NTFY_FAILURE_URL"; ntfy_token="$NTFY_FAILURE_TOKEN"
    hook_url="$WEBHOOK_FAILURE_URL"; hook_auth="$WEBHOOK_FAILURE_AUTH_HEADER"
  else
    kind=report; ntfy_url="$NTFY_URL"; ntfy_token="$NTFY_TOKEN"; hook_url="$WEBHOOK_URL"; hook_auth="$WEBHOOK_AUTH_HEADER"
    case "$NOTIFY_ON" in
      failure)  return 0 ;;
      findings) [ "${SEC:-0}" -gt 0 ] || [ "${BRK:-0}" -gt 0 ] || [ "${URG:-0}" -gt 0 ] || return 0 ;;
    esac
  fi
  [ "$ntfy_url" = none ] && ntfy_url=""; [ "$hook_url" = none ] && hook_url=""   # "none" disables a destination
  [ -n "$ntfy_url$hook_url" ] || return 0

  local link title prio tags body
  link="$(jq -r 'if .outline_url != "" then .outline_url elif .outline_summary_url != "" then .outline_summary_url else "" end' <<<"$DATA")"
  if [ "$CODE" -ne 0 ]; then title="patch-advisor FAILED on $HOST"; prio=4; tags="x"
  elif [ "${SEC:-0}" -gt 0 ]; then title="patch-advisor: $SEC security update(s) on $HOST"; prio=4; tags="warning"
  elif [ "${BRK:-0}" -gt 0 ] || [ "${URG:-0}" -gt 0 ]; then title="patch-advisor: updates need attention on $HOST"; prio=3; tags="warning"
  else title="patch-advisor: $HOST checked"; prio=2; tags="white_check_mark"; fi
  body="$(jq -r --arg d "$DESC" '
      def k: if . >= 1000000 then "\(. / 100000 | floor / 10)M" elif . >= 1000 then "\(. / 100 | floor / 10)k" else "\(.)" end;
      $d,
      "",
      "Upgradable OS packages: \(.upgradable_packages) · Containers: \(.containers) (findings count items, which group related packages)",
      "Mode: \(.mode) · Model: \(if (.models | length) > 0 then (.models | join(", ")) else .model end)",
      "Duration: \(.wall_s / 60 | floor)m \(.wall_s % 60)s · Tokens: \(.total_tokens | k) · Est. cost: $\(.cost_usd)",
      (if .outline_url != "" then "Report: \(.outline_url)" elif .report_file != "" then "Report file: \(.report_file)" else empty end),
      (if .outline_summary_url != "" then "Summary: \(.outline_summary_url)" else empty end),
      (if .saved != "ok" then "Logs: \(.log)" else empty end)' <<<"$DATA")"

  if [ -n "$ntfy_url" ]; then
    local args=(-fsS --max-time 20 -X POST -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" --data-binary "$body")
    [ -n "$link" ] && args+=(-H "Click: $link" -H "Actions: view, Open report, $link")
    [ -n "$ntfy_token" ] && args+=(-H "Authorization: Bearer $ntfy_token")
    curl "${args[@]}" "$ntfy_url" >/dev/null || issue WARN "ntfy $kind notification failed ($ntfy_url)."
  fi
  if [ -n "$hook_url" ]; then
    local payload hargs=(-H "Content-Type: application/json")
    [ -n "$hook_auth" ] && hargs+=(-H "$hook_auth")
    payload="$(jq -c --arg ev "patch-advisor.$kind" --argjson code "$CODE" --arg title "$title" --arg desc "$DESC" --arg text "$title"$'\n'"$body" --arg summary "$SUMMARY_TXT" \
      '{event:$ev, code:$code, status:(if $code == 0 then "success" else "failure" end), title:$title, description:$desc,
        text:$text, summary_text:$summary} + .' <<<"$DATA")"
    curl -fsS --max-time 20 -X POST "${hargs[@]}" --data-binary "$payload" "$hook_url" >/dev/null \
      || issue WARN "Webhook $kind notification failed ($hook_url)."
  fi
}
notify

xy "$CODE" "$DESC" "$DATA"
exit "$CODE"
