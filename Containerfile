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
#
# tesseract is UNgated, unlike paddle: it's ~30MB and it is the toolbelt's
# always-available fallback engine (AUTO_ORDER's last entry), so the default
# image should be able to OCR at all. tesseract-langpack-eng is the Fedora
# spelling of Arch's tesseract-data-eng; without the langpack the binary
# installs fine and then fails at run time with "Error opening data file eng".
#
# NOTE for anyone adding a build ARG: declare it at its first USE, not up here.
# An ARG whose value differs invalidates the layer cache from its declaration
# onward, so a WITH_PADDLE=1 build with the ARG above this line re-runs this
# whole dnf install — the largest layer in the image — instead of sharing it with
# the default tag.
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
      tesseract tesseract-langpack-eng \
  && dnf clean all \
  && rm -rf /var/cache/dnf/*

# CPU PaddleOCR, opt-in (--build-arg WITH_PADDLE=1). Off by default: the wheels
# are ~1GB and only oil-rag wants them. Baked at BUILD time on purpose — the
# build never runs through Squid (it's on the host on Linux, inside the podman
# machine VM on macOS, but outside the proxy either way), so the wheels and the
# PP-OCR model files cost NOTHING at the boundary. The running box then does real
# OCR fully offline, which is the point: no egress added to get a testable engine.
#
# Declared HERE, at its first use, so everything above this line stays cached and
# shared with the default image — see the NOTE on the dnf layer.
ARG WITH_PADDLE=0

# PaddleOCR pulls opencv-python, which links libGL.so.1 — absent from the Fedora
# base image. Without this, `import paddleocr` dies at import time with
# ImportError: libGL.so.1, which reads like a paddle bug and isn't one. Root, so
# it must land before USER agent. mesa-libGL is the package to ask for even
# though the soname actually ships in libglvnd-glx — mesa-libGL pulls it in, and
# it's the name every "libGL.so.1 missing on Fedora" answer uses.
RUN if [ "${WITH_PADDLE}" = 1 ]; then \
      dnf -y --setopt=install_weak_deps=False install mesa-libGL \
      && dnf clean all && rm -rf /var/cache/dnf/* ; \
    fi

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

# --- CPU PaddleOCR, opt-in ---------------------------------------------------
# A SEPARATE 3.12 venv, not the system interpreter: Fedora 44 ships Python 3.14
# and paddlepaddle has no cp314 wheel (3.3.1 tops out at cp313; 2.6.2 at cp312),
# so a plain `pip install paddlepaddle` here fails exactly as it does on the host.
# uv installs a standalone CPython 3.12 without disturbing system python.
#
# 3.12 is the one version that satisfies BOTH sides: paddlepaddle 2.6.2 ships
# cp312, and oilrag-toolbelt declares requires-python >=3.12 — so this venv can
# hold the toolbelt AND paddle, which the engine's in-process
# `from paddleocr import PaddleOCR` requires.
#
# The pins are load-bearing, now for TWO independent reasons:
#
#   1. PaddleEngine._parse_paddle targets the PaddleOCR 2.x return shape
#      ([quad, (text, conf)]); unpinned `paddleocr` resolves to 3.x, whose output
#      shape differs and would SILENTLY break the parser.
#   2. paddlepaddle 2.6.2 is the pin that keeps arm64 working. Paddle publishes
#      manylinux2014_aarch64 wheels up to 3.2.x and DROPPED them at 3.3.0 (that
#      release is x86_64 + macOS-arm64 only). On an Apple Silicon host — where
#      podman builds natively for linux/arm64 — bumping this past 3.2.x means no
#      wheel exists and the layer fails outright.
#
# The rest of the 2.x dependency tree is arm64-clean: shapely, pyclipper, lmdb,
# scikit-image, rapidfuzz and opencv-python all ship cp312 aarch64 wheels, and
# imgaug/albumentations/albucore are pure-Python. Nothing here builds from source.
ARG WITH_PADDLE
ENV OCR_VENV=/home/agent/.venvs/ocr
RUN if [ "${WITH_PADDLE}" = 1 ]; then \
      uv python install 3.12 \
      && uv venv --python 3.12 "${OCR_VENV}" \
      # setuptools is NOT optional: paddle 2.6.2 imports it at package-import
      # time (paddle/utils/cpp_extension), and `uv venv` seeds no setuptools —
      # nor does Python 3.12 ship one implicitly. Without it `import paddle`
      # dies with ModuleNotFoundError before any OCR runs.
      && uv pip install --python "${OCR_VENV}/bin/python" \
           "setuptools==83.0.0" "paddlepaddle==2.6.2" "paddleocr>=2.7,<3" \
      # Warm the model cache into ~/.paddleocr at BUILD time. PaddleOCR otherwise
      # fetches det/rec/cls from bcebos on first use — which the sandbox has no
      # egress for. Baking them is what lets OCR run with no allowlist entry at all.
      && "${OCR_VENV}/bin/python" -c "\
import numpy as np; from paddleocr import PaddleOCR; \
PaddleOCR(use_angle_cls=True, lang='en').ocr(np.full((64,256,3),255,np.uint8), cls=True)" \
      # Drop uv's wheel cache IN THIS LAYER, or ~1GB of downloaded wheels ships
      # inside the image forever — a build cache is not part of a reset point,
      # and deleting it in a later RUN would not shrink the layer that added it.
      # Safe after the installs: uv hardlinks cache entries into the venv, so the
      # venv keeps the inodes alive.
      && uv cache clean ; \
    fi

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
