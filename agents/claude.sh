# Agent profile: claude
#
# Sourced by ./sandbox. Contract:
#   AGENT_CMD[]         argv to exec inside the container
#   AGENT_STATE_DIRS[]  paths under $HOME to persist across runs (dirs)
#   AGENT_STATE_FILES[] paths under $HOME to persist across runs (files)
#   AGENT_ENV[]         KEY=VALUE passed with -e
#   agent_seed_project  optional fn, runs on the host against $1 = project dir

AGENT_CMD=(claude --dangerously-skip-permissions)

AGENT_STATE_DIRS=(".claude")
AGENT_STATE_FILES=(".claude.json")

AGENT_ENV=(
  "DISABLE_UPDATES=1"
)

# Claude Code has its own inner bubblewrap sandbox. The container is the real
# boundary; this is defence in depth and gets us un-prompted bash inside it.
agent_seed_project() {
  local project="$1"
  local dest="$project/.claude/settings.json"
  [[ -f "$dest" ]] && return 0
  mkdir -p "$project/.claude"
  cat > "$dest" <<'JSON'
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,

    "enableWeakerNestedSandbox": true,

    "filesystem": {
      "allowWrite": ["/work"]
    },

    "network": {
      "allowedDomains": [
        "api.anthropic.com",
        "statsig.anthropic.com",
        "github.com",
        "api.github.com",
        "codeload.github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "registry.npmjs.org",
        "pypi.org",
        "files.pythonhosted.org",
        "crates.io",
        "static.crates.io",
        "index.crates.io",
        "proxy.golang.org",
        "sum.golang.org"
      ],
      "allowLocalBinding": true
    },

    "credentials": {
      "files": [
        { "path": "~/.ssh", "mode": "deny" },
        { "path": "~/.aws", "mode": "deny" }
      ],
      "envVars": [
        { "name": "GITHUB_TOKEN", "mode": "deny" },
        { "name": "GH_TOKEN", "mode": "deny" },
        { "name": "NPM_TOKEN", "mode": "deny" },
        { "name": "ANTHROPIC_API_KEY", "mode": "deny" }
      ]
    }
  }
}
JSON
  echo "seeded $dest"
}
