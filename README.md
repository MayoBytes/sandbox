# sandbox

Rootless-podman sandbox for agentic coding tools. Run `claude`, `opencode`, or
`crush` with **no route to the internet** except through a domain-allowlist
proxy, and **none of your host credentials** inside. Agent-agnostic: each ships
as a profile, and adding another is one file.

> Built for Arch Linux and rootless podman, tailored to a single-user setup on
> purpose. Porting to another distro is mostly swapping the `pacman` line.

Two boundaries:

1. **Container** — agent runs as a non-root user with only your project mounted.
   Nothing else from `$HOME` exists to it. No credentials.
2. **Network** — the container sits on a podman `--internal` network. It has
   **no route to the internet at all**. Its only reachable neighbour is a Squid
   proxy enforcing a domain allowlist.

Point 2 is the one that matters. This isn't "we set `HTTP_PROXY` and hope." If
the agent unsets the proxy vars, or a tool ignores them, or something opens a
raw socket to an IP — there is no gateway. It fails closed.

```
┌─ host ────────────────────────────────────────────────────────┐
│                                                               │
│   agent-internal (--internal, no gateway)                     │
│   ┌──────────────────┐        ┌──────────────────┐            │
│   │  agent container │───────▶│   agent-proxy    │            │
│   │  /work = project │        │  squid allowlist │            │
│   │  no creds        │        └────────┬─────────┘            │
│   │  no route out    │                 │                      │
│   └──────────────────┘                 │ agent-egress         │
│                                        ▼                      │
└───────────────────────────────────── internet ────────────────┘
```

## Requirements

- **Linux** (developed on Arch) or **macOS** (Apple Silicon).
- `podman`. On Linux also `aardvark-dns` and `netavark`; on macOS they ship
  inside the VM.
- On Linux, rootless podman needs a non-empty subuid/subgid range for your user
  (the quickstart sets this up). Root is needed only to install packages and to
  grant that range once — never to *run* the sandbox.

The boundary is kernel work: an `--internal` netavark network, dropped
capabilities, cgroup limits, a user namespace. macOS has none of that, so
`podman machine` supplies a real Linux kernel in a VM and the same enforcement
happens there. The agent image and the proxy are identical on both.

## Quickstart

### Linux

```bash
# 1. Install podman + the rootless networking stack.
sudo pacman -S podman aardvark-dns netavark

# 2. Confirm your user has a subuid/subgid range (required for rootless).
grep "^$USER:" /etc/subuid /etc/subgid        # must print two non-empty lines
# If empty:
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

### macOS

```bash
# 1. Install podman.
brew install podman

# 2. Create the VM. Two things here are not the defaults and both matter:
#
#    --memory must exceed the 8g the agent container asks for, or that limit is
#    one the kernel cannot honour and you get OOM-killed mid-session.
#
#    --volume REPLACES the default "share all of $HOME" with just the paths you
#    name. Do this. The default hands your entire home directory to the VM; the
#    container still only sees /work, but there is no reason to widen the VM's
#    view either. Name your code root and the state dir, nothing else.
mkdir -p ~/.local/share/agent-sandbox
podman machine init --cpus 6 --memory 12288 --disk-size 100 \
  --volume "$HOME/git:$HOME/git" \
  --volume "$HOME/.local/share/agent-sandbox:$HOME/.local/share/agent-sandbox"
podman machine start
```

A project outside those shared paths will not error — it would mount **empty**,
and the agent would run against nothing and look like it worked. `./sandbox`
checks for this and refuses, but the fix is to keep projects under a shared root.

### Both

```bash
# 3. Build the agent + proxy images.
chmod +x sandbox
./sandbox --build

# 4. Run an agent. The argument after it is the project dir (default: $PWD).
./sandbox claude
./sandbox opencode ~/code/x
./sandbox crush ~/code/x
```

**On the first run of each agent you'll be asked to log in, inside the
container.** No host credentials are passed in — that's the whole point — so each
agent authenticates itself once. The token lands in that agent's per-project
state dir and persists across runs; it is never shared with your host installs
or with other projects. See [The credential rule](#the-credential-rule).

Then **verify the boundary actually holds** before you trust it — the next
section walks through it, and you should not skip it.

Other commands:

```bash
./sandbox shell ~/code/x   # bash, no agent — for poking at the boundary
./sandbox --logs           # tail the proxy: every request, every denial
./sandbox --down           # tear down proxy + networks
./sandbox --agents         # list available profiles
```

## Verify the boundary before you trust it

Do not skip this. "It started, therefore it's safe" is how people end up with a
sandbox that isn't one.

```bash
./sandbox shell ~/code/my-project
```

Inside:

```bash
# 1. No route out. Should fail, and should NOT resolve.
curl -x '' --max-time 5 https://example.com     # expect: failure
getent hosts example.com                        # expect: nothing

# 2. Proxy denies non-allowlisted domains.
curl --max-time 10 https://example.com          # expect: 403 from squid
curl --max-time 10 https://api.anthropic.com/   # expect: connects

# 3. Home is empty of your real life.
ls -la ~ ; ls ~/.ssh 2>&1                       # expect: no such file

# 4. Host filesystem not visible.
ls /home 2>&1 ; cat /etc/shadow 2>&1

# 5. Files in /work come out owned by YOU on the host.
touch /work/t && stat -c '%U' /work/t && rm /work/t

# 6. The .git guard held: both of these must FAIL.
touch /work/.git/hooks/pre-push           # expect: read-only file system
git -C /work config --local user.name x   # expect: failure
```

Test #1 is your regression check. Re-run it after every podman/netavark
upgrade — `--internal` semantics have shifted before, and a sandbox that
silently stops sandboxing is worse than none, because you're running YOLO in it.

**On macOS, two of these prove less than they do on Linux.** Read them
accordingly rather than ticking them off:

- **#1** now means "no route out of the VM". Still fail-closed, still the right
  check — but your exposure now also tracks `podman machine` and gvproxy
  versions, not just netavark's. Re-run it after upgrading either.
- **#5** passes for a different reason. On Linux it demonstrates
  `--userns keep-id` mapping your uid. On macOS that flag maps the *VM's* user,
  and what you see from the Mac is decided by the virtiofs id mapping — which is
  lax about ownership by design. The file comes out yours; the mechanism is not
  the one the flag names.
- **#6** is worth running on macOS specifically. `.git/config` is a single file,
  rewritten by rename, bind-mounted read-only *inside* the `/work` mount — the
  fragile case for virtiofs. It is also the linchpin of
  [The credential rule](#the-credential-rule), so verify it rather than assume it.

## The credential rule

**No host credentials go in.** Not SSH keys, not `~/.aws`, not `gh` tokens, not
a `.env` with prod secrets. The agent commits; **you** review the diff and push
from the host. This single rule defuses most of what prompt injection could
actually do, and no amount of hypervisor isolation substitutes for it.

Each agent authenticates once *inside* the container (see the quickstart);
tokens land in the per-(agent, project) state dir and persist. They are never
shared with your host installs.

### Reviewing and pushing safely

The project is mounted read-write, `.git` included, so the agent can commit.
The catch: `.git/hooks/*` and `.git/config` are **executable configuration that
runs on your host**, with your privileges, the moment you run `git diff`,
`git log -p`, or `git push` in that working tree. A `pre-push` hook,
`core.sshCommand`, `core.pager`, or a `diff.*.textconv` driver all fire from the
repo you run the command *in* — so a hostile agent that writes them turns your
review step into arbitrary host code execution. Two layers defend against this:

1. **In the sandbox**, `.git/hooks` and `.git/config` are bind-mounted
   read-only. Objects, refs, and the index stay writable — the agent still
   commits normally (committer identity comes from `GIT_COMMITTER_*`, injected
   by `./sandbox`) — but it cannot plant a hook or define a driver/`sshCommand`
   that would run on the host later. Read-only `.git/config` is the linchpin:
   with no way to define a `diff`/`filter` driver, a committed `.gitattributes`
   is inert.

2. **On the host**, review and push from a *fresh clone*, not the working tree.
   A local `git clone` copies objects and refs only — never the source's hooks
   or local config — so it is a clean room:

   ```bash
   git clone ~/code/x /tmp/review
   git -C /tmp/review log -p origin/main..agent-branch   # safe to inspect
   git -C /tmp/review remote add upstream <real-remote>
   git -C /tmp/review push upstream agent-branch
   ```

   `git -c core.hooksPath=/dev/null push` from the working tree is **not**
   enough — `core.sshCommand` still fires on push.

## Why crush especially

From Crush's own docs: `crush.json` is trusted code — any `$(...)` in it runs
at load time with your shell's privileges, **before the UI appears**. They warn
you not to launch Crush in a directory whose `crush.json` you haven't reviewed.

That is arbitrary code execution triggered by `git clone && cd && crush`. Inside
this sandbox that attacker gets: a container, an empty home directory, no keys,
and no route out. Outside it, they get your laptop.

## Adding an agent

Drop `agents/<name>.sh`:

```bash
AGENT_CMD=(mytool --yolo)                     # argv to exec
AGENT_STATE_DIRS=(".config/mytool")           # persist across runs
AGENT_STATE_FILES=()
AGENT_ENV=("MYTOOL_NO_UPDATE=1")

agent_seed_project() { : ; }                  # optional; $1 = project dir
```

Add its domains as `proxy/allowlist.d/20-<name>.txt`, add its install line to
the `Containerfile`. Done.

State is keyed per **(agent, project)** under
`~/.local/share/agent-sandbox/<agent>/<project>/`, so agents don't share
sessions or auth tokens, and one project's agent state can't reach another's.

## Pinning and auto-updates

Every one of these tools wants to update itself at runtime. In a system where
"rebuild the image" is your reset button, that silently breaks the guarantee
that the image is what's actually running. So every update path is disabled:

- **claude**: installed via the *native* installer (npm is deprecated and the
  CLI nags). `DISABLE_AUTOUPDATER=1` is **not enough** — it only stops the
  background check; `claude update` still works. `DISABLE_UPDATES=1` blocks
  every path. Both are set.
- **opencode**: auto-downloads updates on startup. Killed via
  `"autoupdate": false` in the seeded global config.
- **crush**: pinned at the npm install.

The `Containerfile` exposes `CLAUDE_VERSION`, `OPENCODE_VERSION`, and
`CRUSH_VERSION` build args, defaulting to the latest stable channel. Once you
know a version works, pin it — edit the `ARG` defaults, or build the image
manually with `--build-arg` (`./sandbox --build` uses the defaults as-is).

## Optional: PaddleOCR (CPU)

Off by default, as a separate image tag rather than something every project
carries. Measured on Apple Silicon (`podman system df -v`): the paddle tag is
**4.1 GB** against the default tag's **2.0 GB**, and keeping both costs about
**1.0 GB** on top of the default — that's the tag's `UNIQUE SIZE`, since the two
share the base and the large `dnf` layer.

That sharing is why `ARG WITH_PADDLE` is declared at its first use, low in the
`Containerfile`, rather than up with the other build args: an `ARG` whose value
differs invalidates the cache from its declaration onward, so hoisting it makes a
`WITH_PADDLE=1` build re-run the base package install instead of reusing it.

```bash
# build the variant once
SBX_BUILD_ARGS="--build-arg WITH_PADDLE=1" SBX_IMAGE=agent-sandbox:paddle ./sandbox --build

# run against it
SBX_IMAGE=agent-sandbox:paddle ./sandbox claude ~/code/my-ocr-project
```

`SBX_IMAGE` and `SBX_BUILD_ARGS` are general-purpose: any image tag, any extra
`podman build` flags. Without them nothing changes — the default image is built
and run exactly as before.

**Paddle lives in its own Python 3.12 venv at `$OCR_VENV`
(`/home/agent/.venvs/ocr`), not the system interpreter.** Fedora 44 ships Python
3.14 and PaddlePaddle has no cp314 wheel — 3.3.x tops out at cp313, 2.6.2 at
cp312 — so a plain `pip install paddlepaddle` fails in the image exactly as it
does on the host. `uv` installs a standalone 3.12 alongside, leaving system
Python alone. Use it explicitly:

```bash
"$OCR_VENV/bin/python" -m pytest             # or
uv pip install --python "$OCR_VENV/bin/python" -e /work/mypkg
```

**The models are baked at build time, so OCR needs no egress.** PaddleOCR
otherwise fetches det/rec/cls from `bcebos.com` on first use, which a box with no
route out cannot do. Baking them means the *running* box needs **no allowlist
entry to do OCR** — `podman build` runs outside the proxy (on the host on Linux,
inside the VM on macOS, but never through Squid either way), so build-time
downloads cost nothing at the boundary. Verify with the network removed entirely:

```bash
# literal path, not $OCR_VENV — that variable exists inside the image, and your
# host shell would expand it to nothing before podman ever sees it
podman run --rm --network none agent-sandbox:paddle \
  /home/agent/.venvs/ocr/bin/python -c "from paddleocr import PaddleOCR; print('ok')"
```

Four things in that layer are load-bearing. Three fail loudly if you change
them; the first fails *silently*, which is why it's first:

- **`paddleocr>=2.7,<3`** — 3.x changed the return shape of `.ocr()`. Unpinned,
  pip resolves to 3.x and any parser written against the 2.x
  `[quad, (text, conf)]` output breaks *silently*.
- **`paddlepaddle==2.6.2` is also what keeps arm64 working.** Paddle ships
  `manylinux2014_aarch64` wheels through 3.2.x and **dropped them at 3.3.0**,
  which is x86_64 + macOS-arm64 only on PyPI. Since podman on an Apple Silicon
  host builds natively for `linux/arm64`, bumping this past 3.2.x means no wheel
  exists and the layer dies at install. The rest of the tree is fine on arm64:
  shapely, pyclipper, lmdb, scikit-image, rapidfuzz and opencv-python all have
  cp312 aarch64 wheels, and imgaug/albumentations/albucore are pure Python.
- **`setuptools`** — Paddle 2.6.2 imports it at package-import time, and
  `uv venv` seeds no setuptools (nor does Python 3.12 ship one implicitly).
  Without it `import paddle` dies with `ModuleNotFoundError` before any OCR runs.
- **`mesa-libGL`** — PaddleOCR pulls `opencv-python`, which links `libGL.so.1`;
  the Fedora base image has no such library. The failure reads like a paddle bug
  and isn't one. (The soname actually comes from `libglvnd-glx`, which
  `mesa-libGL` pulls in.)

**This is the CPU path, and on both supported hosts it is the only path.** On
macOS there is no GPU option at all: the container runs inside the podman machine
VM, which gets neither Metal nor CUDA passthrough — an Apple Silicon GPU is
simply not visible to it, so don't go looking for a `paddlepaddle-gpu` variant.
On an AMD Linux host it's the only path for a different reason: PaddlePaddle's
ROCm wheels target gfx906/DCU, not RDNA3 (gfx1100, e.g. a 7900 XT), so there is
no working `paddlepaddle-gpu` for those GPUs — in this sandbox or on bare metal.
Don't add `--device /dev/kfd` expecting Paddle to use it. An NVIDIA Linux host is
a different question and would need its own image layer.

Expect it to be slower on arm64 than on x86_64 — Paddle's ARM builds get neither
oneDNN nor MKL. It works; it isn't the fast path.

`proxy/allowlist.d/20-oil-rag.txt` is a separate matter: it opens Paddle's own
wheel index for the GPU wheels, which are not on PyPI and which nothing in this
image installs. Nothing above needs it. It's kept for the case where a Linux box
wants to `pip install paddlepaddle-gpu` at run time; delete the file if you don't
— every line in there widens egress for **every** agent, not just this one.

## Known gaps

- **Squid allowlists by CONNECT hostname, not TLS content.** It doesn't
  terminate TLS, so domain fronting / SNI tricks are theoretically possible.
  Anthropic's docs raise the identical caveat about their own built-in proxy.
  If you need more: swap Squid for mitmproxy with a CA in the image.
- **Every allowlisted domain is an exfil channel.** `github.com` can create
  issues and gists. Provider API endpoints are bidirectional pipes by design.
  The allowlist narrows the channel; it does not close it.
- **The allowlist is a union across all agents.** Adding an agent widens it for
  everyone. If that bothers you, run a proxy container per agent.
- **Notifications are a second channel out, and a real one.** The agent picks
  the text and you read it, so it can encode data into a notification body. What
  makes it an acceptable trade rather than a hole: it's a bare FIFO (no D-Bus —
  see below), the host renders it and can ignore it, the body is capped at ~200
  bytes and rate-limited to one per two seconds, and you're the only receiver.
  It carries no authority in either direction. `SBX_NOTIFY=0 ./sandbox …` opts
  out; the box then has no path back to the host but the proxy.
  The title is *always* host-generated (`sandbox: <agent> — <project>`) so a
  compromised agent can't dress its message up as a system prompt. Note the
  corollary: **never bind-mount the host D-Bus session socket in to get real
  `notify-send`.** The session bus is a desktop control plane — keyring secrets
  via `org.freedesktop.secrets`, arbitrary host exec via systemd `--user` — and
  handing it to the box would end the boundary outright. That's why there's no
  `libnotify` in the image.
- **Notifications don't work on macOS**, and the tool says so instead of
  half-working. Three separate things block it: a host FIFO can't cross virtiofs
  into the VM as a pipe (the shim's `[[ -p $FIFO ]]` check fails and it no-ops),
  the listener needs bash 4 associative arrays and `flock` and macOS has neither,
  and an `osascript` renderer would reintroduce exactly the string-injection
  surface the argv-based `notify-send` call was built to avoid. Any future macOS
  transport has to stay one-way and bytes-only, and keep the host-generated title
  and the size cap — otherwise it's a worse channel than the one it replaces.
- **Container ≠ hypervisor.** A kernel exploit escapes. If you're running
  genuinely hostile *code* (not just untrusted input), add `--runtime` with
  Kata/libkrun — the `podman run` line is the only thing that changes. On macOS
  you get a hypervisor boundary for free, since the whole podman stack already
  runs in a VM — the one respect in which the Mac is the stronger of the two.
  Note the flip side: the VM is a trust surface the Linux host doesn't have, and
  it sees whatever you shared into it at `machine init`. Share narrowly.
- **Claude's inner sandbox uses `enableWeakerNestedSandbox: true`**, because
  bubblewrap can't mount a fresh `/proc` in an unprivileged container. That's
  acceptable here precisely because the container is the real boundary — which
  is the exact condition Anthropic's docs say to use it under.
