#!/usr/bin/env bash
# Update this patch-advisor installation from a release archive, re-apply this server's settings from .env, and run a file-mode test.
# Usage: sudo <install-dir>/bin/update.sh /path/to/patch-advisor-<version>.zip [--no-test]
set -euo pipefail
# Install location = parent of bin/; kept in PA_INSTALL across the re-exec from a temporary copy
INSTALL="${PA_INSTALL:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export PA_INSTALL="$INSTALL" PATCH_ADVISOR_DIR="$INSTALL"

# This script is replaced during the update: run from a temporary copy
if [ -z "${PA_UPDATE_REEXEC:-}" ]; then
  self="$(mktemp)"; cp "$0" "$self"
  PA_UPDATE_REEXEC=1 exec bash "$self" "$@"
fi
trap 'rm -f "$0"' EXIT

USAGE="Usage: sudo $INSTALL/bin/update.sh /path/to/patch-advisor-<version>.zip [--no-test]"
ZIP=""; RUN_TEST=1
for a in "$@"; do
  case "$a" in
    --no-test) RUN_TEST=0 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    -*)        echo "Unknown option: $a"; echo "$USAGE"; exit 1 ;;
    *)         [ -z "$ZIP" ] || { echo "Only one archive allowed."; echo "$USAGE"; exit 1; }; ZIP="$a" ;;
  esac
done
[ -n "$ZIP" ] || { echo "$USAGE"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -f "$ZIP" ] || { echo "Zip not found: $ZIP"; exit 1; }
for t in unzip rsync sha256sum docker; do command -v "$t" >/dev/null || { echo "Needs $t."; exit 1; }; done

# Local settings come from .env (never from the archive)
env_get() { grep -E "^$1=" "$INSTALL/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/' || true; }   # a missing setting is not an error (set -e/pipefail would end the script silently)
OUTLINE_HOST="$(env_get OUTLINE_HOST)"
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; }
if [ -n "$OUTLINE_HOST" ] && ! valid_host "$OUTLINE_HOST"; then echo "Invalid OUTLINE_HOST in $INSTALL/.env: $OUTLINE_HOST (host name only)"; exit 1; fi
UBUNTU_VERSION="$(env_get UBUNTU_VERSION)"

STAGE="${PA_UPDATE_STAGE:-1}"   # 1 = unpack and copy; 2 = continue with the new update.sh after the copy

if [ "$STAGE" = 1 ]; then
# 1. Unpack
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; rm -f "$0"' EXIT
unzip -q "$ZIP" -d "$TMP"
# Find the project inside the archive: top folder "patch-advisor/" (our release archives), "<repo>-<tag>/" (GitHub source
# archives), or no top folder at all (git archive without --prefix). Exactly one project must be found.
mapfile -t FOUND < <(find "$TMP" -maxdepth 3 -type f -path '*/bin/run-patch-advisor.sh' -printf '%h\n' | sed 's#/bin$##' | sort -u)
if [ "${#FOUND[@]}" -ne 1 ]; then
  echo "Unexpected archive layout: expected exactly one patch-advisor project (bin/run-patch-advisor.sh), found ${#FOUND[@]}."
  unzip -l "$ZIP" | head -n 8
  exit 1
fi
SRC="${FOUND[0]}"
[ -f "$SRC/patch-advisor.compose.yml" ] || { echo "Unexpected archive layout: $SRC has no patch-advisor.compose.yml."; exit 1; }
OLD_VERSION="$(cat "$INSTALL/VERSION" 2>/dev/null || echo unknown)"
NEW_VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"
echo "== Updating $INSTALL: $OLD_VERSION -> $NEW_VERSION (see CHANGELOG.md)"

# 2. Copy, keeping everything that belongs to this server
CHANGES="$(rsync -rlpt --itemize-changes --chown=root:root \
  --exclude='.env' --exclude='secrets/' --exclude='data/' --exclude='logs/' --exclude='reports/' --exclude='.build-fingerprint' \
  "$SRC/" "$INSTALL/")"
printf '%s\n' "$CHANGES" | grep -E '^[<>c]' | awk '{print "   changed: " $2}' || echo "   (no file changes)"
chmod 755 "$INSTALL"/bin/*.sh

# The rest of the update must use the new update.sh, so its fixes apply to this update already
if ! cmp -s "$0" "$INSTALL/bin/update.sh"; then
  next="$(mktemp)"; cp "$INSTALL/bin/update.sh" "$next"
  echo "== update.sh changed: continuing with the new version"
  rm -rf "$TMP"; rm -f "$0"; trap - EXIT
  PA_UPDATE_REEXEC=1 PA_UPDATE_STAGE=2 exec bash "$next" "$@"
fi
fi   # end of stage 1

# Keep PATCH_ADVISOR_DIR in .env pointing at this installation (manual docker compose commands read it)
if [ -f "$INSTALL/.env" ]; then
  if grep -qE '^#?PATCH_ADVISOR_DIR=' "$INSTALL/.env"; then sed -i -E "s|^#?PATCH_ADVISOR_DIR=.*|PATCH_ADVISOR_DIR=$INSTALL|" "$INSTALL/.env"
  else printf 'PATCH_ADVISOR_DIR=%s\n' "$INSTALL" >> "$INSTALL/.env"; fi
fi

# 3. Re-apply the Outline host (the archive ships a placeholder)
if [ -n "$OUTLINE_HOST" ]; then
  sed -i "s/your-team\.getoutline\.com/${OUTLINE_HOST}/g" "$INSTALL/config/claude/mcp.json" "$INSTALL/config/nono/patch-advisor.json"
  echo "== Outline host: $OUTLINE_HOST"
else
  echo "== WARNING: OUTLINE_HOST is not set in $INSTALL/.env: outline mode will not work (file mode is fine)"
fi

# 4. Rebuild only if the Dockerfile or UBUNTU_VERSION changed since the last build, or the image is missing
FP_FILE="$INSTALL/.build-fingerprint"   # root-owned location (data/ is writable by UID 1000)
rm -f "$INSTALL/data/.build-fingerprint"  # location used before 0.18.2
FP="$(sha256sum "$INSTALL/build/Dockerfile" | cut -d' ' -f1)-${UBUNTU_VERSION:-default}"
if [ "$(cat "$FP_FILE" 2>/dev/null)" != "$FP" ] || ! docker image inspect patch-advisor:latest >/dev/null 2>&1; then
  echo "== Building the image (Dockerfile or UBUNTU_VERSION changed, or no image yet)"
  docker compose -f "$INSTALL/patch-advisor.compose.yml" build
  echo "$FP" > "$FP_FILE"
else
  echo "== Image is up to date: no rebuild"
fi

# 5. Remove what older versions used (only reports what actually existed)
if docker container inspect patch-advisor-socket-proxy-1 >/dev/null 2>&1; then
  docker rm -f patch-advisor-socket-proxy-1 >/dev/null && echo "== Removed old socket proxy container"
fi
for n in patch-advisor_internal patch-advisor_egress; do
  if docker network inspect "$n" >/dev/null 2>&1; then docker network rm "$n" >/dev/null && echo "== Removed old network $n"; fi
done
rm -rf "$INSTALL/data/proxy"

# 6. Test run in file mode (no Outline writes)
[ "$RUN_TEST" -eq 1 ] || { echo "== Done (test skipped)"; exit 0; }
echo "== Test run (file mode)"
ISSUES_BEFORE="$(wc -l < "$INSTALL/logs/issues.log" 2>/dev/null || echo 0)"
set +e
PATCH_ADVISOR_MODE=file "$INSTALL/bin/run-patch-advisor.sh"
RC=$?
set -e
echo
echo "== Exit code: $RC"
echo "== Latest report: $(ls -t "$INSTALL"/reports/*/*.md 2>/dev/null | head -n1 || echo none)"
echo "== Issues of this run:"
NEW_ISSUES="$(tail -n +"$((ISSUES_BEFORE + 1))" "$INSTALL/logs/issues.log" 2>/dev/null)"
if [ -n "$NEW_ISSUES" ]; then printf '%s\n' "$NEW_ISSUES" | sed 's/^/   /'; else echo "   (none)"; fi
exit "$RC"
