# AGENTS.md

Context for AI agents and human contributors working on **patch-advisor**. Read this before changing anything.
If `AGENTS.local.md` exists (it is git-ignored), read it too: it holds the maintainer's private context (servers, preferences).

---

## 1. What this project is

A read-only update auditor for a Linux server. On each run, Claude Code (inside a nono sandbox, inside a Docker container) receives an
inventory of the host's upgradable OS packages and running containers, researches newer versions, release notes and known
vulnerabilities on the internet, classifies every update (🔴 Security, 🟠 Breaking, 🟡 Urgent, 🟢 Routine) and writes a report to
Outline (or, in file mode, a Markdown file). **It is just a script:** `bin/run-patch-advisor.sh` runs one audit and exits; it can be started
by hand, from cron, a systemd timer or any scheduler. xyOps is the maintainer's scheduler and is documented, but nothing may depend on it.

**The agent must never be able to change anything on the server.** Every design decision below serves that rule.

Current state: see `VERSION` and `CHANGELOG.md`. Pre-1.0. What is verified in production and what is not: README, "Tested with".

---

## 2. How a run works

```
any trigger (by hand, cron, systemd, xyOps, …) → bin/run-patch-advisor.sh   (the "wrapper": bash, root, on the host or in a scheduler's container with the Docker socket)
  1. preflight: secrets (not placeholders), image, nono pack, Docker Compose
  2. inventory (trusted side, fixed commands, before the agent exists):
     - container "inventory" (no network, host package data read-only): bin/collect-packages.sh → data/inventory/
     - wrapper itself: docker ps / inspect / image inspect / image history → data/inventory/docker/ (filtered, redacted)
  3. container "patch-advisor" (fresh, removed afterwards): nono run --profile patch-advisor --allow-cwd -- claude -p ... --output-format stream-json
     - reads /work/inventory (read-only), /work/CLAUDE.md (read-only), researches online, writes /work/cache, report to Outline or /work/reports
     - final line: RESULT security=N breaking=N urgent=N routine=N complete=yes|no saved=ok|failed [url=… summary_url=…] [file=…]
  4. wrapper: parses RESULT (untrusted!), validates URLs/paths, writes logs, stats, xyOps wire-protocol lines, notifications
```

Exit codes: 0 done, 1 run failed, 2 report not saved (fallback file in outline mode), 3 audit incomplete.
Result output: `PATCH_ADVISOR_OUTPUT=xyops` (default: xyOps wire-protocol JSON lines) or `plain` (one readable line). Keep xyOps-specific
behaviour behind this switch or in the README's xyOps section; the script must stay usable without xyOps.

---

## 3. Repository map

| Path | Purpose |
|---|---|
| `bin/run-patch-advisor.sh` | The wrapper (entry point for xyOps and manual runs). Biggest and most security-sensitive file. |
| `bin/collect-packages.sh` | Runs inside the `inventory` container: dpkg-query, apt list --upgradable, os-release, kernel. |
| `bin/run-summary.sh` | Runs inside the nono sandbox before Claude Code (compose command: `nono run … -- pa-run-summary claude …`): prints the run settings, then `exec`s Claude Code. Reads `data/inventory/run-info.env` (non-secret facts written by the wrapper). |
| `bin/setup.sh` | First-time setup; idempotent. `--outline-host`, `--skip-build`, `--container-tools`. |
| `bin/update.sh` | Updates an install from a release zip; re-execs from a temp copy and hands over to the new version after copying. |
| `patch-advisor.compose.yml` | Services `patch-advisor` (audit) and `inventory` (profile `inventory`). All host paths via `${PATCH_ADVISOR_DIR}`. |
| `build/Dockerfile` | Ubuntu (`UBUNTU_VERSION` build arg) + Claude Code + nono. No Docker CLI. |
| `config/claude/{outline,file}/CLAUDE.md` | The agent's instructions per job type. Shared sections must stay identical in both. |
| `config/claude/{outline,file}/settings.json` | Claude Code permissions (headless: anything not allowed is refused). |
| `config/claude/mcp.json` | Outline MCP connection (placeholder host `your-team.getoutline.com`). |
| `config/nono/patch-advisor.json` | nono profile: network allowlist with method/path rules, credential routes, `filesystem.read_file`. |
| `config/nono/patch-advisor-apikey.json` | Same, with a Console API key instead of the subscription token. |
| `config/apt/apt.conf` | apt in the inventory container: package cache in memory. |
| `.env.example` | All settings; `.env` is per server (git-ignored). |
| `README.md` | User documentation (has a generated table of contents). |
| `CHANGELOG.md`, `VERSION` | Keep a Changelog + SemVer. |

Do not confuse the root `CLAUDE.md` (pointer for coding agents working on this repo) with `config/claude/*/CLAUDE.md` (the audit agent's instructions).

---

## 4. Security invariants (never break these)

1. **The agent has no write path to the host** beyond its own folders: `data/home` (Claude Code state), `data/work` (cache, temp), `reports/`.
   No Docker socket, no host package data, no host files except the read-only inventory snapshot and its config.
2. **The agent never touches apt, dpkg or Docker.** The inventory is collected by the wrapper before the agent starts.
3. **Container env and command lines are never collected** (they contain passwords). Image env is reduced to version-like variables;
   build-history lines are redacted (tokens, Authorization headers, `user:pw@`).
4. **Tokens never enter the agent's process**: nono's credential proxy injects them; Claude Code only sees placeholders.
5. **Everything the agent outputs is untrusted**: RESULT values are validated (counts numeric, URLs must start with the configured Outline
   origin, report files must be regular files really inside `reports/`); agent output lines starting with `{` are prefixed with `» ` so they
   can never be parsed as xyOps protocol messages (which can trigger actions).
6. **The wrapper runs as root and must never follow a symlink in a UID-1000-writable path** (`data/home`, `data/work`, `reports/`).
   Use `safe_under`, `mktemp` + `mv -T`, never `chown`/`>` on such paths directly. `data/` itself is root-owned; lock and fingerprint live in
   root-owned places (`logs/.run.lock`, `.build-fingerprint`).
7. **Event parameters and `.env` are validated**: profile (only the two shipped), model name, host name, numeric settings; `.env` is loaded
   through a whitelist (never `PATH`, `LD_*`, `BASH_ENV`).
8. **stdin of the audit container is closed** (xyOps passes the job document on stdin; `claude -p` would append it to the prompt).
9. **No private data in the repository**: placeholders for hosts; `*.local.md`, `.env`, `secrets/`, `data/`, `logs/`, `reports/`, `tools/`,
   `.build-fingerprint` are git-ignored. Release archives are built from git, never from a working folder.
10. **Downloads are pinned and verified**: `setup.sh --container-tools` embeds SHA-256 checksums in the script.

---

## 5. Design decisions and abandoned alternatives (do not reintroduce)

| Decision | Why / what was tried before |
|---|---|
| Inventory on the trusted side, agent reads a snapshot | Earlier: agent ran apt/docker itself via nono command policies + a Docker socket proxy (Tecnativa, then wollomatic, then via unix socket). Caused shims in noexec `/tmp`, DNS problems in command sandboxes, fixed IPs that could collide with office networks. All removed in 0.10.0. |
| No project networks, no fixed IPs | Audit container uses Docker's default `bridge`; inventory container has `network_mode: none`. |
| Claude Code permission rules use absolute paths `Edit(//work/...)` | `./` rules are relative to the shell's *current* directory; a `cd` broke all writes. `cd` is denied. |
| Wrapper marks `/work` as trusted in `.claude.json` | Claude Code ignores a project's `settings.json` in untrusted folders; headless runs cannot answer the trust prompt. Written safely (invariant 6). |
| `--allow-cwd`, `CLAUDE_CODE_TMPDIR=/work/.tmp`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | Non-interactive nono skips the cwd grant; `/tmp` is outside the sandbox; telemetry hit the allowlist. |
| nono pack `nolabs-ai/claude` installed once, `NONO_NO_MIGRATE=1` | The `claude-code` profile is a registry pack since nono 0.43; runs must never install packs. |
| `filesystem.read_file: /etc/bash.bashrc` | Otherwise every shell call prints "Permission denied" (noise and tokens). nono `fs_read` takes directories only. |
| Outline "reports home" is a **parent document** (e.g. "Patch Reports") | The Outline MCP tools cannot list or create collections; an empty collection is invisible to document search. |
| Outline mode fallback file in `reports/` | A failed Outline save must not lose the report. |
| Host document: `## Current status` (replaced every run) + dated history sections | Requested by the maintainer; the summary document is rewritten for this server on every run (rows of this server come back if deleted). |
| WebSearch tool not allowed | Runs outside nono's network control; GitHub repository search is allowed instead. |
| Default time limit 6 minutes | Real runs take 1–3 minutes. |
| Install location via `PATCH_ADVISOR_DIR` | `/opt/patch-advisor` was hard-coded; other locations failed. Scripts derive their own location. |
| Compose resolved into a command array `COMPOSE=(...)` | `timeout` cannot run shell functions (0.21.0 bug). |
| xySat in Docker: one mount + `tools/` (jq, compose) | Keeps the xySat container portable; no privileged `nsenter` hand-over (rejected as too broad), no host-binary mounts (host `jq` needs host libraries). |
| Agent-side classification rules in CLAUDE.md, from scratch each run | Copying categories from earlier reports produced inconsistent results. |
| Categories count items **and** packages; totals counted by the wrapper | Grouping made counts look inconsistent with `apt` and the login message; exact totals come from the inventory, not the agent. |
| Only stable releases count as "newest"; moving tags (`latest`) resolved by digest | |
| Reports in English | Maintainer's choice (Bulgarian search terms remain so existing Outline content is found). |

---

## 6. Conventions

- **SemVer** (pre-1.0: minor = features/behavior changes, patch = fixes). Every change: bump `VERSION`, add a `CHANGELOG.md` entry
  (Keep a Changelog sections: Added / Changed / Fixed / Security / Removed), newest first.
- **Release archive:** `patch-advisor-<version>.zip` with top folder `patch-advisor/`; exclude `tools/` and anything git-ignored.
- **README:** keep it in sync with every behavior change; regenerate the table of contents (GitHub anchor rules) and check that all
  internal links resolve.
- **Both CLAUDE.md files:** sections shared by both modes (rules, inventory, steps, classification, cache, commands) must stay identical;
  only the saving sections differ.
- **No company or server names** anywhere in tracked files. Use placeholders (`your-team.getoutline.com`, `server01`).
- **Explain commands** in user-facing docs ("What it does: …").
- **Scripts:** bash, `set -uo pipefail` (wrapper) / `set -euo pipefail` (setup, update); must pass `bash -n` and ShellCheck (warnings).

---

## 7. Testing

There is no CI yet. Before a release:

```bash
for f in bin/*.sh; do bash -n "$f"; done
shellcheck -S warning bin/*.sh            # pip install shellcheck-py
python3 -c "import json,yaml; [json.load(open(f)) for f in ['config/nono/patch-advisor.json','config/nono/patch-advisor-apikey.json','config/claude/mcp.json','config/claude/outline/settings.json','config/claude/file/settings.json']]; yaml.safe_load(open('patch-advisor.compose.yml'))"
PATCH_ADVISOR_DIR=/srv/patch-advisor docker compose -f patch-advisor.compose.yml config   # all paths resolve to the given dir
git grep -n -i -E '<your company/server names>' || echo clean
```

Wrapper logic is tested with a **fake `docker`** script on `PATH` that replays a Claude `stream-json` session (see CHANGELOG history for
cases covered: prompt-injected `{"xy":…}` lines, foreign URLs, symlink attacks on `.claude.json` and report files, stdin leakage, abort
handling, OOM vs. timeout, usage limits, placeholder secrets, newline stripping, `.env` whitelist, compose fallback).
Real validation on a server: file mode first (`PATCH_ADVISOR_MODE=file`), then outline mode.

---

## 8. Lessons learned (gotchas)

- Docker mounts tmpfs `noexec` by default.
- `timeout` needs a real command, not a shell function.
- `set -euo pipefail` + `grep` for an optional setting that is missing ends the script **silently** (fixed in 0.25.0 in `env_get`): end such pipelines with `|| true`.
- `chown`, `>`, `sed -i` follow symlinks; `rm -rf` and `find -P` do not.
- Claude Code: `./` permission paths are cwd-relative; untrusted folders ignore project settings; headless refuses anything not allowed;
  `claude -p` reads stdin; update responses may not contain document URLs (the wrapper remembers the last valid ones).
- nono: `fs_read` only takes directories; command policies need shims in an executable `/tmp`; command sandboxes have no DNS.
- Ubuntu image tags: release only (`24.04`), never point releases (`24.04.5`).
- Outline MCP: documents can be created as children of a parent document; collections cannot be listed or created; `fullWidth` exists in
  the Outline API but may not be exposed by the MCP tools.
- EUVD: use `/api/search` (max 100 per page), always send a user agent; cisa.gov KEV was dropped in favour of EUVD (EU source).
- OSV: Ubuntu ecosystem is `Ubuntu:<release>:LTS`; use source package names; `/v1/query` per package returns fixed versions.

---

## 9. Open items

- Verify in production: full audit started from a containerized xySat, xyOps job table/chart and abort, ntfy/webhook notifications,
  API-key profile, Debian hosts, GHCR/Quay images.
- Possible next steps: time in dated section headings when running several times a day; CI with ShellCheck and the stub tests;
  pinning Claude Code and nono versions in the Dockerfile.
