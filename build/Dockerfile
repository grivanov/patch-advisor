# patch-advisor: Claude Code + nono (the audit agent), plus the tools the inventory collector uses (apt, dpkg-query).
# Base: latest stable Ubuntu (26.04 LTS). If apt has trouble reading an older host's package data,
# set UBUNTU_VERSION to the host's release, e.g. 24.04 (or its codename, noble).
# Use the release only: Docker Hub has no point-release tags like 24.04.5. For reproducible builds,
# use a dated tag that exists on Docker Hub, e.g. noble-YYYYMMDD.
ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/* \
    # nono, copied to a root-owned location the agent cannot modify
    && curl -fsSL https://nono.sh/install.sh | sh \
    && NONO_BIN="$(command -v nono || ls /root/.local/bin/nono /root/.cargo/bin/nono 2>/dev/null | head -n1)" \
    && { [ "$NONO_BIN" = /usr/local/bin/nono ] || install -m 0755 "$NONO_BIN" /usr/local/bin/nono; } \
    # Claude Code native binary, same treatment (/home/agent is bind-mounted at runtime)
    && curl -fsSL https://claude.ai/install.sh | bash \
    && install -m 0755 "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude \
    && rm -rf /root/.local /root/.cargo \
    # Ubuntu ships a 'ubuntu' user with UID 1000; replace it with 'agent'
    && { userdel -r ubuntu 2>/dev/null || true; } \
    && useradd -u 1000 -U -d /home/agent -m -s /bin/bash agent \
    && mkdir -p /work && chown agent:agent /work \
    && nono --version && claude --version

# Read-only root filesystem at runtime: update by rebuilding, not self-updating
ENV DISABLE_AUTOUPDATER=1 \
    HOME=/home/agent

USER agent
WORKDIR /work
