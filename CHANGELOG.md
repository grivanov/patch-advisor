# Changelog

All notable changes to patch-advisor. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/): before 1.0.0, minor versions may contain breaking changes.
The installed version is in the `VERSION` file and is shown in every run log, run summary and the xyOps job data.
Dates are in UTC. Versions 0.1.0 to 0.10.0 were assigned afterwards, when versioning was introduced in 0.11.0; they group the earlier development steps.

## [0.25.1] - 2026-10-13

### Fixed
- `bin/update.sh` rejected GitHub source archives ("Unexpected archive layout"), because it required the top folder to be named exactly `patch-advisor/`. It now finds the project inside the archive: top folder `patch-advisor/`, `<repo>-<tag>/` (GitHub releases and tags), or no top folder (`git archive` without `--prefix`). An archive with more than one project is refused, with the archive's top entries shown.

## [0.25.0] - 2026-10-13

### Added
- **Run settings summary** before every audit, in the terminal and the run log: run ID and version, mode and destination (Outline MCP server URL or report folder), model and authentication type, time limit, age of the host's package lists (with a warning above 2 days), inventory counts and host OS, cache state and age (EUVD list age, number of release-note summaries, or "cleared for this run"), the network allowlist, Claude Code and nono versions, notification targets (host names only), output format, and the last run's result. Printed by the new `bin/run-summary.sh` **inside the nono sandbox**, right before Claude Code starts, so it shows what the run really uses and cannot expose secrets. Facts the sandbox cannot see are prepared by the wrapper in `data/inventory/run-info.env`, without secrets.

### Fixed
- `bin/update.sh` and `bin/setup.sh` ended **silently** (no output, exit code 0) when an optional setting such as `UBUNTU_VERSION` was missing from `.env` (since 0.15.0): `grep` finding nothing ended the script under `set -euo pipefail`. Found by a regression run of all earlier test scenarios (35 checks, all passing).

## [0.24.0] - 2026-10-13

### Added
- `PATCH_ADVISOR_OUTPUT=plain`: ends a run with one readable `Result: exit code N: …` line instead of the xyOps JSON lines, e.g. for cron or systemd. The default (`xyops`) is unchanged.
- README: new section "Running and scheduling" with examples for running by hand, cron and a systemd timer, and notes for any other scheduler (exit codes, per-run settings, lock, time limit, running from a container).

### Changed
- README: patch-advisor is presented as what it is, a script that runs one audit; xyOps is documented as the author's setup in its own section ("xyOps (the author's setup)", with "xyOps event" and "xySat in Docker"). Generic topics that used to sit inside the xyOps section are now top-level or under "Running and scheduling": job types, notifications, several servers, exit codes and output, and settings for one run (now listed by environment variable, with the xyOps parameter name alongside).

## [0.23.1] - 2026-10-13

### Fixed
- Changelog dates: all entries had the same date. They now show the actual release dates (UTC), reconstructed from file timestamps and run logs: 0.1.0–0.5.0 on 2026-10-09, 0.6.0–0.21.2 on 2026-10-10, 0.22.0 and later on 2026-10-13.

## [0.23.0] - 2026-10-13

### Added
- **Items and packages:** every category now shows the number of items and of packages in them (e.g. `🔴 2 items (5 packages)`), plus the total of upgradable OS packages, in file reports, the host document's `Current status` and the summary (new column "Upgradable packages"). A note under the tables explains the grouping and that Ubuntu's login message ("N updates can be applied") is computed and cached separately. Required in `CLAUDE.md`, independent of the structure document.
- The wrapper counts the exact totals itself from the inventory (`upgradable_packages`, `containers`): in the run summary, the job data, the xyOps table and notifications.
- README: "Items and packages" explanation and a troubleshooting entry for counts that differ from the login message.

## [0.22.0] - 2026-10-13

### Added
- `AGENTS.md`: context for AI agents and contributors (architecture, security invariants, design decisions and abandoned alternatives, conventions, testing, lessons learned, open items). A short root `CLAUDE.md` points coding agents to it. Private context belongs in `AGENTS.local.md` (git-ignored by the `*.local.md` rule).
- README "Contributing" section.
- Outline mode: Claude sets the server document and the summary to **full width** (Outline's `fullWidth` option) when its Outline tools allow it, so the tables use the whole page.

### Fixed
- Notifications sometimes had no Outline link: on runs that only updated existing documents, Claude did not return the URLs. `CLAUDE.md` now requires them on every run, and the wrapper remembers the last valid URLs (in `logs/.outline-urls`) and uses them when a run omits them (logged as a warning).

## [0.21.2] - 2026-10-10

Final review before publication (ShellCheck clean apart from intentional constructs; no leftovers of earlier designs; no private data).

### Security
- The wrapper (running as root) now loads only patch-advisor's own settings from `.env` (`PATCH_ADVISOR_*`, `OUTLINE_HOST`, `UBUNTU_VERSION`, `AUDIT_PROMPT`, `MAX_SECONDS`, retention, notification settings). Other variables, such as `PATH`, `LD_PRELOAD` or `BASH_ENV`, are ignored instead of being passed to every program it starts.

### Changed
- README "Tested with": starting the wrapper from a containerized xySat and collecting the inventory through the host's Docker are verified.

## [0.21.1] - 2026-10-10

### Fixed
- The audit did not start when Docker Compose came from `tools/` or the plugin (`timeout: failed to run command 'dcompose'`): 0.21.0 called Compose through a shell function, which `timeout` cannot run. The Compose command is now resolved once into a plain command.
- Preflight check: a missing Docker Compose is reported up front with the fix (install the plugin, or `setup.sh --container-tools`).

## [0.21.0] - 2026-10-10

### Added
- **Containerized xySat with one mount:** `bin/setup.sh --container-tools` downloads self-contained builds of `jq` (1.7.1) and Docker Compose (v2.29.7) into `tools/`, with the SHA-256 checksums embedded in the script (a tampered download is refused). The wrapper uses them only where the system has none, so a xySat container needs just the Docker socket, a `docker` CLI and the patch-advisor folder mounted at the same path. No custom xySat image and no host-specific binary mounts.

### Changed
- README "xySat in Docker" rewritten for this setup; native xySat remains the simplest option.

## [0.20.0] - 2026-10-10

### Changed
- **Any install location works.** Previously `/opt/patch-advisor` was built into the compose file and the scripts, so another location (e.g. `/srv/patch-advisor`) failed with `unable to prepare context: path "/opt/patch-advisor/build" not found` and every update reset hand-made path changes. Now the scripts find their own folder, `bin/setup.sh` writes it to `.env` as `PATCH_ADVISOR_DIR` (also after moving the folder), the wrapper and `bin/update.sh` set it on every run, and the compose file uses it for all paths. Without it, Compose stops with a clear message.

### Fixed
- `bin/setup.sh --outline-host HOST` failed with "valid_host: command not found" (since 0.18.2): the host check was defined after the option parsing that uses it.

## [0.19.2] - 2026-10-10

### Changed
- README: "Tested with" now also lists what is implemented but not yet verified in production (xyOps integration, notifications, API-key profile, xySat in Docker, Debian hosts, non-Docker-Hub registries); the run summary example is version-neutral.

## [0.19.1] - 2026-10-10

### Changed
- The summary's "Last updated" line, each server's "Last check" in the summary and in its `Current status` section now show date, time and time zone (the server's local time, e.g. `2026-10-10 23:15 EEST`), not only the date.

## [0.19.0] - 2026-10-10

### Added
- **`## Current status` in each server document:** directly below the server description, a table of this host's open items from the latest audit (priority, component, installed and latest version, action and notes), replaced on every run. The dated sections below remain the history.

### Changed
- **The summary document is updated on every run**, also when nothing changed: "last updated", this server's "last check", and all of this server's rows rewritten from the current audit. Deleted rows of this server come back if the item still applies. Previously a run with no changes could skip the summary, and rows deleted by people were never restored.
- Both rules are required in `CLAUDE.md` and apply even if the structure document in Outline describes the documents differently.
- "Never restore removed content" now applies to older dated sections, other servers' rows and manually added content, not to a server's own generated parts.

## [0.18.3] - 2026-10-10

### Fixed
- Claude printed `ISSUE version unknown: none` to say there was no problem, which the wrapper logged as a warning. `CLAUDE.md` now says to print no `ISSUE` line when there is nothing to report, and the wrapper ignores lines ending in "none", "n/a" or "nothing".

## [0.18.2] - 2026-10-10

Security review before publication.

### Security
- **Privilege escalation via symlinks:** the wrapper (running as root) updated Claude Code's `.claude.json` in the agent's home with `jq … > file.tmp`, `mv` and `chown`, all of which follow symbolic links. A link planted there by the agent or by any host user with UID 1000 could have made root overwrite or change the ownership of arbitrary files (e.g. `/etc/shadow`). The file is now written through a freshly created temporary file and an atomic rename, and the wrapper refuses to touch it if it or its directory is a symlink.
- **Reading files through symlinks:** a report path returned by the agent was used by root (line-break repair, notifications) even if it was a symlink or lay in a symlinked directory. Report files are now accepted only as regular files really inside `reports/`.
- `data/` itself is now root-owned (its subdirectories stay owned by UID 1000), and the run lock and the build fingerprint moved out of `data/` (to `logs/.run.lock` and `.build-fingerprint`), so nothing writable by UID 1000 can redirect root's writes.
- Credentials in image build history lines (`TOKEN=…`, `Authorization: Bearer/token …`, `user:password@` in URLs) are redacted before the inventory reaches the agent.
- The Outline host from `.env` or `--outline-host` is validated (host name and optional port only) before it is used in `sed`.

### Fixed
- `bin/update.sh` rejects unknown options (e.g. a misspelled `--notest` was silently ignored) and more than one archive.
- Lines of the package collector's log in the job output are prefixed, so they can never be read as xyOps protocol messages.
- The changelog no longer names a company.

## [0.18.1] - 2026-10-10

### Added
- `*.local.md` files are ignored by git, for server-specific notes; updates leave them in place.

## [0.18.0] - 2026-10-10

First successful Outline-mode run: reports are created under the "Patch Reports" parent document.

### Added
- `bin/setup.sh`: first-time setup in one command. Checks prerequisites and Landlock, sets permissions, creates the directories, `.env` (server name, Outline host, the host's Ubuntu release) and **placeholder secrets**, applies the Outline host, builds the image, installs the nono Claude pack and checks the inventory collection. Safe to re-run; never overwrites `.env` or real secrets.
- Preflight recognizes the placeholder secrets: the Claude token must always be real; the Outline token only in outline mode.
- Trailing newlines and carriage returns in the secret files (as added by editors such as nano) are removed before each run.

### Changed
- **Default time limit is now 6 minutes** (`MAX_SECONDS=360`, was 1 hour); runs take 1–3 minutes. The recommended xyOps max run time is 8 minutes.
- README brought up to date: installation via the setup script, current example outputs, job data fields (`version`, Outline URLs, fallback file), Customization and Troubleshooting entries, and a "Tested with" section replacing "To verify on first deployment" (all items there are confirmed).

### Fixed
- README: a leftover row in the xyOps parameter table, references to installation steps that no longer exist, and command policies (removed in 0.10.0) still listed under Customization.

## [0.17.0] - 2026-10-10

### Changed
- The reports home in Outline is now usually a **parent document** (e.g. "Patch Reports"): Claude finds it by searching documents and creates the structure document, the server documents and the summary as child documents under it. A collection still works if the Outline tools can list collections. (The Outline MCP tools could not list collections, so an empty collection was never found.)
- `ISSUE outline no collection` is now `ISSUE outline no reports home`, with instructions to create a parent document or collection.
- `state.json` must be written with the Write tool every run; printing it with `jq` does not save it.

## [0.16.0] - 2026-10-10

First Outline-mode run: the Outline MCP connection works through nono's credential proxy (the real token never reaches Claude Code).

### Changed
- Claude finds the reports collection by **listing collections** instead of searching documents; a new, empty collection is invisible to document search.
- The Outline MCP tools cannot create collections: the collection must be created by an admin (now a required installation step). Without a suitable collection, Claude reports `ISSUE outline no collection` with what to do.

### Added
- Fallback in outline mode: if saving to Outline is not possible, the report is written to `reports/<server>/<date_time>.md` (the job still ends with code 2, and its description names the file).

## [0.15.3] - 2026-10-10

### Changed
- Security fixes that a vendor announces without CVE/GHSA ids now count as **Security** (noted as "no CVE/GHSA ids published") instead of Routine.

### Added
- GitHub repository search (`GET /search/repositories`) to find a project's repository when its release notes are not obvious.

### Fixed
- Claude tried the WebSearch tool, which is refused: `CLAUDE.md` now says it is not available and points to GitHub's repository search. WebSearch stays disallowed because it runs outside nono's network control.

## [0.15.2] - 2026-10-10

### Fixed
- `bin/update.sh` ran as the previously installed version for the whole update, so its own fixes only took effect one update later. After copying the new files it now hands over to the new `update.sh` for the remaining steps (Outline host, rebuild check, cleanup, test). Takes effect from the next update on, because this update still starts with the 0.15.1 updater.
- `state.json` had no exact format, so runs stored different things (all packages, or only upgradable ones). It now always holds `last_run`, the upgradable packages with installed and candidate version, and the containers with image, digest and version.

## [0.15.1] - 2026-10-10

Runs with a warm cache now take under a minute (46 s, about 300k tokens, against 2 minutes and 780k tokens before).

### Fixed
- `bin/update.sh` listed all of today's issues as "Issues of this run"; it now shows only the lines added by the test run.
- Claude carried over categories from the previous report instead of applying the classification rules: items are now classified from scratch on every run, earlier reports are not an input, and file mode does not read earlier reports.
- Release-note summaries were cached only for some items; now for every item whose notes were read, including its security and breaking points.
- `state.json` was not written when the inventory was unchanged; it is now always written with today's `last_run`.

## [0.15.0] - 2026-10-10

### Added
- `bin/update.sh`: updates the install from a release archive (copies the files, keeps local data, re-applies the Outline host, rebuilds only when needed, runs a file-mode test). Replaces the separate `update-and-test.sh`.
- `.env` settings `OUTLINE_HOST` (re-applied after every update) and `UBUNTU_VERSION` (passed to the image build as an argument; the Dockerfile is no longer edited locally).
- "Updating" section in the README.
- Required final step for the agent: update the cache (`state.json`, release-note summaries, vulnerability data), so the next run can detect changes.

### Changed
- Precise classification rules: "breaking" covers anything that requires action or changes behavior (config, migrations, API/CLI changes including exit codes, defaults); an item fitting several categories goes into the first one and its other aspects are marked (e.g. `⚠ breaking: ...` on a Security item).
- The rebuild decision uses a fingerprint of the Dockerfile and `UBUNTU_VERSION`, so re-applying local settings no longer triggers a rebuild.

### Fixed
- The first EUVD download failed because the cache folder did not exist yet (`curl --create-dirs`).
- Pointless `POST` requests to OSV's `/v1/vulns/<id>` (GET only).

## [0.14.1] - 2026-10-10

First fully successful run (exit 0, complete, report saved, no refused tool calls). Fixes from that run:

### Fixed
- The EUVD exploited list was downloaded several times per run and never cached. It is now saved once a day with `curl -o` into `/work/cache/euvd/page_<n>.json` and all CVEs are checked against those files in one query.
- Reading the report back covered only its first lines; the whole file (or Outline document) must now be read.
- `ISSUE` lines must go into Claude's final output, not into the report, so the wrapper's issues log collects them.
- Every shell call printed `/etc/bash.bashrc: Permission denied`: the nono profile now allows reading that file (`filesystem.read_file`).

## [0.14.0] - 2026-10-10

### Fixed
- All writes (report, cache) were refused after Claude ran `cd`: the permission rules used `./` paths, which Claude Code resolves against the shell's current directory. All path rules are now absolute (`Edit(//work/cache/**)`, `Edit(//work/reports/**)`, and the deny rules for `CLAUDE.md`, `.claude/` and `.mcp.json`).
- `cd` is denied (`Bash(cd:*)`), and writing to `/work/inventory` is denied explicitly.

### Added
- Packages from third-party repositories (e.g. Docker, containerd, vendor desktop apps) are checked against their upstream project (OSV upstream ecosystems, GitHub Advisory Database, project advisories) instead of being reported as an unreachable source.
- Release notes are required reading for minor and major version changes; patch-level updates get a quick scan.

## [0.13.0] - 2026-10-10

### Changed
- Reports are written in **English**: file-mode reports, Outline documents (server documents, summary, default structure), `ISSUE` lines and Claude's final output. Previously Bulgarian.
- The default structure's headings are now `🔴 Security`, `🟠 Breaking changes`, `🟡 Urgent`, `🟢 Routine`, and the markers `⚠ actively exploited`, `No updates available.` and `No changes since YYYY-MM-DD.`
- Claude still searches Outline with Bulgarian terms as well, so an existing collection with a Bulgarian name is found; new content in it is written in English.

## [0.12.0] - 2026-10-10

First complete end-to-end run on a real server (2 security and 4 routine findings in about one minute). Improvements from that run:

### Changed
- Audit scope defined explicitly: vulnerabilities are checked for the items that have an update (upgradable OS packages, container images with a newer version); packages without an update are out of scope.
- `complete=no` now only means a real gap (missing inventory, a whole source unreachable); limits of depth are reported as `ISSUE` lines but do not make the audit incomplete.
- OSV lookups use `POST /v1/query` once per source package (full records with fixed versions) instead of one request per vulnerability.
- EUVD: every CVE is checked against the cached list of exploited vulnerabilities instead of individual lookups.
- Moving tags: page back through up to 5 pages of Docker Hub tags to find the installed digest.

### Added
- "Fixed by the update?" check: each record's fixed version is compared with the candidate version; vulnerabilities that stay open after the update are reported as such.
- Reading the saved report back is now an explicit, required step (file mode and Outline).

### Fixed
- Shell loops (`for`, `while`) are refused in headless mode; `CLAUDE.md` now forbids them and points to batch endpoints.
- Update script: no longer reports removing a socket proxy container that did not exist, and no longer rebuilds the image when only the local `UBUNTU_VERSION` setting was re-applied.

## [0.11.0] - 2026-10-10

### Added
- `VERSION` file and this changelog; release archives are named `patch-advisor-<version>.zip`.
- The version appears in the run start line, the run summary and the job data (`version`).
- Clear message when the Claude account's usage limit is reached ("Claude usage limit reached: ... rerun after the reset") instead of a generic failure.
- Markdown formatting rules in both `CLAUDE.md` files: real line breaks only, blank lines between blocks, bullet lists instead of stacked lines, a blank line after tables, read the result back after saving.
- Safety net in the wrapper: a file-mode report written as one line with literal `\n` sequences is converted to real line breaks (logged as a warning).

### Fixed
- Report templates that caused merged lines and broken tables: the summary is now a bullet list, item details are bullet lists under a heading, and the note under the summary table is separated by a blank line.

## [0.10.0] - 2026-10-10

### Changed
- **Redesign: the inventory is collected on the trusted side.** The wrapper collects the host's packages (in a short-lived `inventory` container without network, host package data read-only) and the running containers and images (Docker CLI, version-relevant fields only) before the agent starts. The agent reads the snapshot from `/work/inventory/` (read-only) and has no access to apt, dpkg or Docker.
- The audit container uses Docker's default `bridge` network; the project creates no networks or address ranges.
- The Docker inventory never includes container environment variables or command lines; image environment is reduced to version-like variables.

### Removed
- The socket proxy (`wollomatic/socket-proxy`), its socket directory and `DOCKER_GID`.
- nono command policies, shims and the `exec` exception on `/tmp`.
- The Docker CLI from the image.

## [0.9.0] - 2026-10-10

### Changed
- The socket proxy served its API on a Unix socket in `data/proxy/` with no network (replaced in 0.10.0).

### Removed
- The internal Docker network, its fixed subnet `172.30.250.0/28` and the proxy's fixed IP (they could collide with real networks).

## [0.8.0] - 2026-10-10

First deployment on a real server; fixes for everything it surfaced.

### Added
- Preflight checks before a run: both secret files, the built image and the nono Claude pack must exist.
- Installation of the nono pack `nolabs-ai/claude` (the `claude-code` profile became a registry pack in nono 0.43); `NONO_NO_MIGRATE=1` so runs never install packs.
- `complete=yes|no` in the RESULT line and exit code 3 for incomplete audits (a partial audit no longer looks like a clean server).
- Host timezone in the container; read-only helper commands for the agent; "one command per call" rules in `CLAUDE.md`.

### Fixed
- `--allow-cwd`: the sandbox had no access to the working directory in non-interactive runs.
- Claude Code's temp directory moved to `/work/.tmp` (`CLAUDE_CODE_TMPDIR`); `/tmp` is outside the sandbox.
- Claude Code ignored `settings.json` in untrusted folders: the wrapper marks `/work` as trusted.
- Telemetry disabled (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`) instead of allowing a telemetry domain.
- apt and Docker access inside the sandbox (several iterations, superseded by the 0.10.0 redesign).
- Ubuntu image tag: release numbers only (`24.04`), Docker Hub has no point-release tags.

## [0.7.0] - 2026-10-10

Review fixes.

### Fixed
- Security: the Outline host had been corrupted by a path rename into a different, possibly foreign host name, which could have sent the Outline token there; now a placeholder that the installation replaces.
- Security: the xyOps job document (stdin) reached Claude's prompt; the audit container now gets an empty stdin.
- Security: agent output could fake xyOps protocol lines (job result, actions); lines starting with `{` are prefixed with `» `.
- Security: event parameters could select a weaker nono profile; profile and model names are validated.
- Security: report URLs in notifications are accepted only from the configured Outline instance.
- Aborting a job now stops the run immediately and releases the lock; out-of-memory kills are no longer reported as timeouts; failures use exit code 1, the container's code is in `rc`.
- Host OS taken from the host's `/etc/os-release` instead of the container's.
- The Outline safety rule no longer blocks legitimate summary updates; people may clean up documents at any time.

## [0.6.0] - 2026-10-10

### Added
- Notifications after each run to ntfy and/or a webhook, with the Outline link; separate destinations for reports and failures; `NOTIFY_ON`.
- Run statistics from Claude Code's stream output: duration, turns, tokens, estimated cost; run summary, `logs/stats.jsonl`, xyOps table and performance chart.
- Containers on moving tags (`latest`): version from labels, version variables, build history or registry digest; update detection by digest.
- Only stable releases count as "newest" (pre-releases are skipped).

## [0.5.0] - 2026-10-09

### Added
- Vulnerability and lifecycle sources: OSV.dev, GitHub Advisory Database, Ubuntu/Debian security data, ENISA EUVD (exploited vulnerabilities), endoflife.date.
- Cache in `data/work/cache/` so unchanged data is not fetched again; release notes re-read when they change upstream; `PATCH_ADVISOR_REFRESH`.
- `PATCH_ADVISOR_MODEL` to choose the Claude model.

## [0.4.0] - 2026-10-09

### Added
- Job types: `outline` (default) and `file` (Markdown report, no Outline) via `PATCH_ADVISOR_MODE`.
- `.env.example`, `.gitignore`, security model documentation, table of contents in the README.

### Changed
- Installation path `/opt/patch-advisor`; company-specific values replaced with placeholders for a public repository.

## [0.3.0] - 2026-10-09

### Added
- Ubuntu 26.04 LTS base image, Docker CLI 29.x, hardened socket proxy, per-server `.env`.
- Logs: per-run logs, `issues.log` with self-rotation (no system logrotate), CPU and memory limits.
- Token documentation (Claude `setup-token`, Outline API key) and rotation.
- Support for xySat running in Docker.

## [0.2.0] - 2026-10-09

### Added
- xyOps integration: `bin/run-patch-advisor.sh` with lock, timeout, cleanup and xyOps wire-protocol result.
- Outline structure discovery: per-server document with dated sections, summary table, structure document.
- One fresh container per run (`docker compose run`).

## [0.1.0] - 2026-10-09

### Added
- First version: read-only audit of OS packages and Docker containers with Claude Code in a nono sandbox, Docker socket proxy, Outline MCP through nono's credential proxy, subscription or API-key authentication.
