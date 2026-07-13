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
