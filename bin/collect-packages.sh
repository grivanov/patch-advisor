#!/bin/bash
# Runs inside the short-lived "inventory" container (no network, host package data read-only).
# Writes the host's OS and package inventory to /out for the audit agent. Fixed commands only; no agent involved.
set -uo pipefail
export APT_CONFIG=/etc/patch-advisor/apt.conf   # apt builds its package cache in memory (no writes)
OUT=/out
fail=0

cp /host/os-release "$OUT/os-release" || fail=1
uname -r > "$OUT/kernel.txt" || fail=1

# Installed packages: binary name, version, source package, source version (tab-separated)
dpkg-query -W -f='${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n' \
  > "$OUT/packages-installed.tsv" 2> "$OUT/packages-installed.err" || fail=1

# Upgradable packages, as apt shows them: name/suites candidate arch [upgradable from: installed]
# The suites tell which updates come from the security pocket (e.g. noble-security).
apt list --upgradable 2> "$OUT/packages-upgradable.err" | grep -v '^Listing' > "$OUT/packages-upgradable.txt"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1

# When the host last refreshed its package lists (apt-daily.timer); stale lists mean stale "upgradable" data
stat -c '%y' /var/lib/apt/lists 2>/dev/null > "$OUT/package-lists-updated.txt"

find "$OUT" -name '*.err' -empty -delete
exit "$fail"
