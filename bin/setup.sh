#!/usr/bin/env bash
# First-time setup of patch-advisor on this server. Safe to re-run: never overwrites .env or real secrets.
# Usage: sudo <install-dir>/bin/setup.sh [--outline-host HOST] [--skip-build] [--container-tools]   (e.g. /opt/patch-advisor)
#   --container-tools: also download jq and Docker Compose into tools/, for running the wrapper from a containerized xySat
set -euo pipefail
INSTALL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"   # install location = parent of bin/
PLACEHOLDER_PREFIX="REPLACE_ME"

ok()   { echo "   ✓ $*"; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; }
warn() { echo "   ! $*"; }
step() { echo; echo "== $*"; }

OUTLINE_HOST_ARG=""; SKIP_BUILD=0; CONTAINER_TOOLS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --outline-host) OUTLINE_HOST_ARG="${2:?--outline-host needs a value}"; shift 2
                    valid_host "$OUTLINE_HOST_ARG" || { echo "Invalid Outline host: $OUTLINE_HOST_ARG (host name only, e.g. your-team.getoutline.com)"; exit 1; } ;;
    --skip-build)   SKIP_BUILD=1; shift ;;
    --container-tools) CONTAINER_TOOLS=1; shift ;;
    -h|--help)      sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done


[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -f "$INSTALL/bin/run-patch-advisor.sh" ] && [ -f "$INSTALL/patch-advisor.compose.yml" ] \
  || { echo "Run setup.sh from the bin/ folder of an unpacked patch-advisor (e.g. /opt/patch-advisor/bin/setup.sh)."; exit 1; }
case "$INSTALL" in *[[:space:]]*) echo "The install path must not contain spaces: $INSTALL"; exit 1 ;; esac
export PATCH_ADVISOR_DIR="$INSTALL"
echo "Install location: $INSTALL"

# ---------------------------------------------------------------------------
step "1. Checking prerequisites"
missing=()
for t in docker jq flock timeout pkill rsync unzip sha256sum; do command -v "$t" >/dev/null || missing+=("$t"); done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "   Missing tools: ${missing[*]}"
  echo "   Install them, e.g.: sudo apt install jq rsync unzip procps util-linux coreutils (Docker: see docs.docker.com)"
  exit 1
fi
docker compose version >/dev/null 2>&1 || { echo "   The Docker Compose plugin is missing (docker compose)."; exit 1; }
ok "tools: docker compose, jq, flock, timeout, pkill, rsync, unzip, sha256sum"
if grep -qw landlock /sys/kernel/security/lsm 2>/dev/null; then ok "Landlock is enabled in the kernel"
else warn "Landlock not found in /sys/kernel/security/lsm: nono may refuse to run (needs a Landlock-enabled kernel)"; fi

# ---------------------------------------------------------------------------
step "2. Files, directories and permissions"
# Code and config belong to root, so the agent (UID 1000) cannot change them
for p in bin build config patch-advisor.compose.yml README.md CHANGELOG.md VERSION .env.example .gitignore; do
  [ -e "$INSTALL/$p" ] && chown -R root:root "$INSTALL/$p"
done
chmod 755 "$INSTALL"/bin/*.sh
mkdir -p "$INSTALL"/data/home/.config/nono/profiles "$INSTALL"/data/work "$INSTALL"/data/inventory \
         "$INSTALL"/reports "$INSTALL"/logs "$INSTALL"/secrets
chown root:root "$INSTALL/data" && chmod 755 "$INSTALL/data"   # data/ itself stays root's: UID 1000 may only write inside the subdirectories
chown -R 1000:1000 "$INSTALL"/data/home "$INSTALL"/data/work "$INSTALL"/data/inventory "$INSTALL/reports"   # container user: state, cache, reports
chown root:root "$INSTALL/secrets" && chmod 700 "$INSTALL/secrets"
ok "code and data/ owned by root; data/home, data/work, data/inventory and reports/ owned by UID 1000; secrets/ mode 700"

# ---------------------------------------------------------------------------
step "3. Per-server settings (.env)"
ENV="$INSTALL/.env"
set_env() {  # set_env KEY VALUE: replace an existing (also commented) line, or append
  if grep -qE "^#?$1=" "$ENV"; then sed -i -E "s|^#?$1=.*|$1=$2|" "$ENV"; else printf '%s=%s\n' "$1" "$2" >> "$ENV"; fi
}
if [ ! -f "$ENV" ]; then
  cp "$INSTALL/.env.example" "$ENV"
  set_env PATCH_ADVISOR_HOST "$(hostname)"
  . /etc/os-release 2>/dev/null || true
  if [ "${ID:-}" = ubuntu ] && [ -n "${VERSION_ID:-}" ]; then set_env UBUNTU_VERSION "$VERSION_ID"; fi
  ok "created .env (server name $(hostname)${VERSION_ID:+, Ubuntu $VERSION_ID})"
else
  ok ".env exists: kept"
fi
[ -n "$OUTLINE_HOST_ARG" ] && { set_env OUTLINE_HOST "$OUTLINE_HOST_ARG"; ok "OUTLINE_HOST=$OUTLINE_HOST_ARG"; }
set_env PATCH_ADVISOR_DIR "$INSTALL"   # always the real location (also after moving the folder)
ok "PATCH_ADVISOR_DIR=$INSTALL"
chown root:root "$ENV" && chmod 600 "$ENV"
env_get() { grep -E "^$1=" "$ENV" | tail -n1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/' || true; }   # a missing setting is not an error (set -e/pipefail would end the script silently)
OUTLINE_HOST="$(env_get OUTLINE_HOST)"; UBUNTU_VERSION="$(env_get UBUNTU_VERSION)"
if [ -n "$OUTLINE_HOST" ] && ! valid_host "$OUTLINE_HOST"; then echo "   Invalid OUTLINE_HOST in $ENV: $OUTLINE_HOST"; exit 1; fi
[ -n "$OUTLINE_HOST" ] || warn "OUTLINE_HOST is empty: set it in $ENV (or re-run with --outline-host HOST) before using outline mode"

# ---------------------------------------------------------------------------
step "4. Secrets (placeholders)"
for f in anthropic_credential outline_token; do
  path="$INSTALL/secrets/$f"
  if [ ! -s "$path" ]; then
    printf '%s_%s' "$PLACEHOLDER_PREFIX" "$f" > "$path"
    ok "$f: placeholder created; replace it before the first run (see README, \"Tokens\")"
  elif grep -q "^$PLACEHOLDER_PREFIX" "$path"; then
    warn "$f: still a placeholder"
  else
    ok "$f: set"
  fi
  chown 1000:1000 "$path" && chmod 400 "$path"
done

# ---------------------------------------------------------------------------
step "5. Outline host in the config"
if [ -n "$OUTLINE_HOST" ]; then
  sed -i "s/your-team\.getoutline\.com/${OUTLINE_HOST}/g" "$INSTALL/config/claude/mcp.json" "$INSTALL/config/nono/patch-advisor.json"
  ok "config points to https://$OUTLINE_HOST"
else
  warn "skipped (no OUTLINE_HOST)"
fi

# ---------------------------------------------------------------------------
step "6. Image"
if [ "$SKIP_BUILD" -eq 1 ]; then
  warn "build skipped (--skip-build)"
else
  docker compose -f "$INSTALL/patch-advisor.compose.yml" build
  # same fingerprint as bin/update.sh, so the next update does not rebuild needlessly
  echo "$(sha256sum "$INSTALL/build/Dockerfile" | cut -d' ' -f1)-${UBUNTU_VERSION:-default}" > "$INSTALL/.build-fingerprint"
  ok "image patch-advisor:latest built"
fi

# ---------------------------------------------------------------------------
step "7. nono Claude pack"
if grep -qs '"[^"]*/claude' "$INSTALL/data/home/.config/nono/packages/lockfile.json"; then
  ok "already installed"
elif docker image inspect patch-advisor:latest >/dev/null 2>&1; then
  docker compose -f "$INSTALL/patch-advisor.compose.yml" run --rm -T patch-advisor nono pull nolabs-ai/claude </dev/null
  ok "installed nolabs-ai/claude"
else
  warn "skipped: build the image first"
fi

# ---------------------------------------------------------------------------
step "8. Inventory check"
if docker image inspect patch-advisor:latest >/dev/null 2>&1 \
   && docker compose -f "$INSTALL/patch-advisor.compose.yml" run --rm -T inventory </dev/null >/dev/null 2>&1; then
  ok "$(wc -l < "$INSTALL/data/inventory/packages-installed.tsv") packages installed, $(wc -l < "$INSTALL/data/inventory/packages-upgradable.txt") upgradable"
  chown -R 1000:1000 "$INSTALL/data/inventory"
else
  warn "inventory collection failed or skipped; see README \"Troubleshooting\""
fi

# ---------------------------------------------------------------------------
step "9. Tools for a containerized xySat (--container-tools)"
if [ "$CONTAINER_TOOLS" -eq 1 ]; then
  # Self-contained builds, pinned versions, checksums embedded here (not downloaded next to the files)
  JQ_VERSION=1.7.1; COMPOSE_VERSION=v2.29.7
  case "$(uname -m)" in
    x86_64)  JQ_FILE=jq-linux-amd64; JQ_SHA=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5
             DC_FILE=docker-compose-linux-x86_64;  DC_SHA=383ce6698cd5d5bbf958d2c8489ed75094e34a77d340404d9f32c4ae9e12baf0 ;;
    aarch64) JQ_FILE=jq-linux-arm64; JQ_SHA=4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5
             DC_FILE=docker-compose-linux-aarch64; DC_SHA=6e9fbd5daa20dca5d7d89145081ae8155d68ef2928b497d9f85b54fe0f9dbb2c ;;
    *) echo "   Unsupported CPU architecture for --container-tools: $(uname -m)"; exit 1 ;;
  esac
  command -v curl >/dev/null || { echo "   --container-tools needs curl"; exit 1; }
  fetch() {  # fetch URL TARGET SHA256
    local tmp; tmp="$(mktemp)"
    curl -fsSL -o "$tmp" "$1" || { rm -f "$tmp"; echo "   Download failed: $1"; exit 1; }
    if [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$3" ]; then rm -f "$tmp"; echo "   Checksum mismatch for $1: not installed"; exit 1; fi
    install -m 755 -o root -g root "$tmp" "$2"; rm -f "$tmp"
  }
  mkdir -p "$INSTALL/tools" && chown root:root "$INSTALL/tools" && chmod 755 "$INSTALL/tools"
  fetch "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/$JQ_FILE" "$INSTALL/tools/jq" "$JQ_SHA"
  fetch "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/$DC_FILE" "$INSTALL/tools/docker-compose" "$DC_SHA"
  ok "tools/jq $JQ_VERSION and tools/docker-compose $COMPOSE_VERSION (checksums verified); used only where the system has none"
else
  ok "not requested (only needed when xySat runs in a container: see README, \"xySat in Docker\")"
fi

# ---------------------------------------------------------------------------
cat <<NEXT

== Setup done. Remaining manual steps:

1. Replace the two placeholder secrets with the real tokens (README, "Tokens: create, install and rotate"):
     sudo nano $INSTALL/secrets/anthropic_credential   # Claude token from 'claude setup-token'
     sudo nano $INSTALL/secrets/outline_token          # Outline API key of the service user
   Replace the whole line with the token, save (Ctrl+O, Enter) and exit (Ctrl+X). A trailing newline is removed automatically.
2. In Outline, create the reports home: a parent document such as "Patch Reports" in a collection
   the service user can edit (README, "Outline API key").
3. Test: sudo PATCH_ADVISOR_MODE=file $INSTALL/bin/run-patch-advisor.sh
   then:   sudo $INSTALL/bin/run-patch-advisor.sh
4. Create the xyOps event (README, "xyOps event").
NEXT
