# Agent sandbox image — agent-agnostic base + pinned agent installs.
#
# Fedora, not Arch, for one reason: it publishes an official multi-arch manifest.
# The official archlinux image is amd64-only, so on an arm64 host the only
# choices were emulation (slow, and bubblewrap + the seccomp helper under
# qemu-user is a gamble) or an unofficial single-maintainer ARM rebuild — a
# supply-chain trade not worth making underneath a security boundary. One base
# for every host keeps ONE reset point, which is the invariant that matters.
FROM registry.fedoraproject.org/fedora:44

# Pin everything. The image IS your reset point; an agent that can update
# itself at runtime means "rebuild" no longer guarantees a known state.
ARG CLAUDE_VERSION=stable
ARG OPENCODE_VERSION=latest
ARG CRUSH_VERSION=latest

# install_weak_deps=False: recommends are not part of a reset point you can
# reason about. shadow-utils because the Fedora base image has no useradd.
RUN dnf -y --setopt=install_weak_deps=False install \
      git \
      nodejs npm \
      python3 python3-pip uv \
      golang \
      rust cargo \
      ripgrep fd-find jq \
      curl wget \
      less vim-enhanced \
      ca-certificates \
      bubblewrap socat \
      shadow-utils \
  && dnf clean all \
  && rm -rf /var/cache/dnf/*

# Notifications go out over a pipe, not D-Bus — deliberately NO libnotify here.
# Real notify-send needs the host session bus, which is a desktop control plane
# (keyring secrets, systemd --user exec), not a message channel. This shim takes
# its place on PATH and writes to the FIFO ./sandbox mounts at /run/sandbox-notify.
COPY --chmod=755 notify/notify-send /usr/local/bin/notify-send

RUN useradd -m -u 1000 -s /bin/bash agent
USER agent
ENV HOME=/home/agent
ENV NPM_CONFIG_PREFIX=/home/agent/.npm-global
ENV PATH=/home/agent/.local/bin:/home/agent/.opencode/bin:/home/agent/.npm-global/bin:$PATH

# --- claude -----------------------------------------------------------------
# Native installer (npm is deprecated and the CLI nags about it). It accepts a
# version number or a channel (stable|latest). Lands at ~/.local/bin/claude.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"

# The seccomp helper for Claude's inner bubblewrap sandbox is npm-only.
RUN npm install -g @anthropic-ai/sandbox-runtime

# --- opencode ---------------------------------------------------------------
# Native installer, NOT npm. The npm package (opencode-ai) ships a placeholder
# bin/opencode.exe and relies on a postinstall to fetch the real platform binary
# from an optional dependency. That postinstall silently no-ops in this build,
# leaving a shebang-less stub — so exec'ing it dies with "Exec format error".
# The installer drops a proper ELF at ~/.opencode/bin/opencode instead.
# OPENCODE_VERSION=latest -> newest release; otherwise pin the exact version.
RUN if [ "${OPENCODE_VERSION}" = "latest" ]; then \
      curl -fsSL https://opencode.ai/install | bash; \
    else \
      curl -fsSL https://opencode.ai/install | bash -s -- --version "${OPENCODE_VERSION}"; \
    fi

# --- crush ------------------------------------------------------------------
RUN npm install -g "@charmland/crush@${CRUSH_VERSION}"

# --- language servers -------------------------------------------------------
# For opencode's LSP integration. Baked in rather than left to opencode's
# runtime auto-download: the sandbox has no general egress and the image is the
# reset point. opencode is pinned to these via explicit lsp.command in
# agents/opencode.sh, so TS/Python never hit the download path. (Auto-download
# stays enabled for other languages — allowlist its hosts if you want it.)
# typescript-language-server -> TS/JS, pyright(-langserver) -> Python. Both
# resolve project deps from the workspace (node_modules / venv), which the agent
# still populates through the proxy.
RUN npm install -g typescript typescript-language-server pyright

# --- freeze the install trees ----------------------------------------------
# DISABLE_AUTOUPDATER only stops the *background* check; `claude update` and
# `claude install` still work. DISABLE_UPDATES blocks every update path, which
# is what we actually want: nothing mutates the image from inside.
ENV DISABLE_UPDATES=1
ENV DISABLE_AUTOUPDATER=1
# opencode's equivalent lives in its config file (autoupdate: false) — see
# agents/opencode.sh, which seeds it.

WORKDIR /work
CMD ["/bin/bash"]
