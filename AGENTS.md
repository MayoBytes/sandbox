# AGENTS.md

Guidance for coding agents working on this repository. For *user*-facing docs
(install, usage, threat model) read `README.md` first — this file is about
changing the code without breaking what it's for.

## What this is

A rootless-podman sandbox that runs agentic coding tools (`claude`, `opencode`,
`crush`) with no route to the internet except through a Squid domain-allowlist
proxy. The whole point is the security boundary. Every change is judged against
whether it preserves that boundary.

## Layout

- `sandbox` — the entrypoint. Bash. Builds images, manages networks/proxy, and
  execs the agent container. Agent-agnostic: nothing below the profile-loading
  line knows which agent is running.
- `agents/<name>.sh` — per-agent profile, sourced by `sandbox`. Defines
  `AGENT_CMD`, `AGENT_STATE_DIRS`, `AGENT_STATE_FILES`, `AGENT_ENV`, and an
  optional `agent_seed_project` function. Adding an agent = adding one file here.
- `Containerfile` — the agent image (Arch base). Pinned tool installs.
- `proxy/` — the Squid image, its `squid.conf`, and `allowlist.d/*.txt`.
- `proxy/allowlist.generated.txt` — **generated**, git-ignored. Never edit by
  hand; it's rebuilt from `allowlist.d/*.txt` by `render_allowlist()` in
  `sandbox`. Edit the `.d/` sources instead.

## Invariants — do not break these

These are the boundary. A change that weakens any of them defeats the tool and
must be called out explicitly, never made silently.

1. **The internal network has no gateway.** It's created with
   `podman network create --internal`. The agent container attaches to it and to
   nothing else. Egress exists *only* because the proxy is dual-homed onto both
   the internal net and a separate egress net. Don't attach the agent container
   to any other network, and don't give the internal net a route out.
2. **The proxy is the sole egress path and enforces the allowlist.** Don't add
   bypasses. New reachable domains go in `allowlist.d/`, and every added domain
   is a bidirectional exfil channel — justify it.
3. **No host credentials enter the container.** No SSH keys, cloud creds, or
   tokens mounted in. Only the project (`/work`) and per-(agent,project) state.
4. **`.git/hooks` and `.git/config` are bind-mounted read-only.** They're
   host-executing config (hooks, `core.sshCommand`, `diff.*.textconv`). Keep the
   `git_guard` mounts in `run_agent`. Objects/refs/index stay writable so the
   agent can still commit.
5. **Hardening flags on `podman run` stay on**: `--userns keep-id`,
   `--security-opt no-new-privileges`, `--cap-drop ALL` (the proxy adds back
   only SETUID/SETGID), `--pids-limit`, `--memory`.
6. **The image is the reset point.** Auto-update is disabled for every tool
   (`DISABLE_UPDATES=1`, opencode `autoupdate: false`, crush pinned). A change
   that lets a tool mutate itself at runtime breaks "rebuild = known state".

## Conventions

- **Voice.** Comments explain *why*, not *what*, and are dense — see the
  existing `.git` guard and network comments. Match that. A non-obvious line
  gets a reason.
- **Bash.** `sandbox` runs `set -euo pipefail`. Keep it. Quote expansions;
  guard array expansions with `${arr[@]:-}`.
- **Adding an agent.** Drop `agents/<name>.sh`, add its domains as
  `proxy/allowlist.d/20-<name>.txt`, add its install to `Containerfile`. Prefer
  the tool's native/pinned installer over one that self-updates.
- **This repo is Arch- and single-user-tailored on purpose.** Don't generalize
  it (other distros, multi-user) unless asked — see README framing.

## Build / test

There is no CI and no test suite. Verification is manual and mandatory after
changes to the boundary:

```bash
./sandbox --build
./sandbox shell ~/some/project   # then run the boundary checks in README
                                 # ("Verify the boundary before you trust it")
```

Test #1 in that section (no route out, no DNS resolution for a non-allowlisted
host) is the regression check. If a change touches networking, run it.
