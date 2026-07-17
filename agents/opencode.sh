# Agent profile: opencode (sst/opencode)

# No YOLO flag needed. opencode permits all operations by default — the
# `permission` config option is how you ADD friction, not remove it. Which
# means it is *especially* worth running behind a real boundary.
AGENT_CMD=(opencode)

AGENT_STATE_DIRS=(
  ".config/opencode"        # opencode.json, agents/, commands/, plugins/
  ".local/share/opencode"   # auth tokens, session data
  ".cache/uv"               # uv download cache — persist so installs aren't cold each run
)
AGENT_STATE_FILES=()

AGENT_ENV=()

# opencode has no notification config knob — a plugin is the only route to
# "tell me when you're done". session.idle is the event that means exactly that:
# it stopped and wants you back. Plugins load at startup from the config dir
# (both plugin/ and plugins/ are scanned; singular is what's in the binary).
#
# notify-send here is our shim, NOT libnotify — it writes one line to the FIFO
# at /run/sandbox-notify and the host renders it. Title and urgency are omitted
# deliberately: the host owns those (see notify/listener), and anything passed
# would be dropped on the floor anyway.
seed_notify_plugin() {
  local plug="$AGENT_STATE_ROOT/.config/opencode/plugin/sandbox-notify.js"
  [[ -f "$plug" ]] && return 0
  mkdir -p "$(dirname "$plug")"
  cat > "$plug" <<'JS'
// Seeded by ./sandbox (agents/opencode.sh). Notifies the host desktop through
// the sandbox FIFO when the session goes idle. try/catch on purpose: a broken
// notification must never take opencode down with it.
export const SandboxNotify = async ({ $ }) => ({
  "session.idle": async () => {
    try { await $`notify-send -- "session idle — your turn"` } catch {}
  },
})
JS
  echo "seeded $plug"
}

agent_seed_project() {
  local project="$1"
  # opencode's global config lives in the persisted state dir, not the project.
  # We seed it once, on the host, in the per-project state root.
  local gcfg="$AGENT_STATE_ROOT/.config/opencode/opencode.json"
  seed_notify_plugin        # guarded separately: state roots predating it still get one
  [[ -f "$gcfg" ]] && return 0
  mkdir -p "$(dirname "$gcfg")"
  cat > "$gcfg" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",

  "autoupdate": false,

  "permission": {
    "*": "allow",
    "edit": "allow",
    "webfetch": "allow",
    "external_directory": "ask"
  },

  "lsp": {
    "typescript": {
      "command": ["typescript-language-server", "--stdio"],
      "extensions": [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"]
    },
    "pyright": {
      "command": ["pyright-langserver", "--stdio"],
      "extensions": [".py", ".pyi"]
    }
  }
}
JSON
  echo "seeded $gcfg"
}
