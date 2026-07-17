# Agent profile: crush (charmbracelet/crush)
#
# !! READ THIS !!
# Crush's own docs: "crush.json is trusted code. Any $(...) in it runs at load
# time with your shell's privileges, before the UI appears. Don't launch Crush
# in a directory whose crush.json you haven't reviewed."
#
# That is arbitrary code execution triggered by `cd repo && crush`. Cloning an
# untrusted repo is enough. This sandbox is not optional for crush — it is the
# thing standing between a hostile crush.json and your actual machine.

AGENT_CMD=(crush --yolo)

AGENT_STATE_DIRS=(
  ".config/crush"        # crush.json (global)
  ".local/share/crush"   # ephemeral state, oauth tokens, recent models
)
AGENT_STATE_FILES=()

AGENT_ENV=()

# No notification hook, deliberately. Crush implements exactly one hook event as
# of 0.85 — PreToolUse — which fires before *every* tool call; wiring notify-send
# to that is a firehose, not a notification. The events that would actually mean
# "your turn" (Stop / SessionEnd / Notification) are on Charm's list but not
# shipped. Nothing to do here until they land, at which point the config shape is
#   {"hooks": {"Stop": [{"command": "notify-send -- 'done'"}]}}
# in crush.json. The notify-send shim is already in the image and on PATH, so
# that is the whole change. Don't reach for PreToolUse in the meantime.

# Crush also writes a per-project .crush/ (SQLite session db) into the working
# directory. That lands inside the bind-mounted project, which is what we want:
# it's project state, it should live with the project. Add to .gitignore —
# crush creates one inside .crush/ automatically, but belt and braces.
agent_seed_project() {
  local project="$1"
  local ignore="$project/.git/info/exclude"
  if [[ -f "$ignore" ]] && ! grep -qx '.crush/' "$ignore" 2>/dev/null; then
    echo '.crush/' >> "$ignore"
  fi
}
