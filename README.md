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

- Arch Linux (or a distro where you can install the equivalent packages).
- `podman`, `aardvark-dns`, `netavark`.
- Rootless podman: a non-empty subuid/subgid range for your user (the quickstart
  sets this up). Root is needed only to install packages and to grant that range
  once — never to *run* the sandbox.

## Quickstart

```bash
# 1. Install podman + the rootless networking stack.
sudo pacman -S podman aardvark-dns netavark

# 2. Confirm your user has a subuid/subgid range (required for rootless).
grep "^$USER:" /etc/subuid /etc/subgid        # must print two non-empty lines
# If empty:
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate

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
```

Test #1 is your regression check. Re-run it after every podman/netavark
upgrade — `--internal` semantics have shifted before, and a sandbox that
silently stops sandboxing is worse than none, because you're running YOLO in it.

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
- **Container ≠ hypervisor.** A kernel exploit escapes. If you're running
  genuinely hostile *code* (not just untrusted input), add `--runtime` with
  Kata/libkrun — the `podman run` line is the only thing that changes.
- **Claude's inner sandbox uses `enableWeakerNestedSandbox: true`**, because
  bubblewrap can't mount a fresh `/proc` in an unprivileged container. That's
  acceptable here precisely because the container is the real boundary — which
  is the exact condition Anthropic's docs say to use it under.
