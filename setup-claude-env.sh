#!/usr/bin/env bash
#
# setup-claude-env.sh - configure a Claude Code environment on this Mac,
# mirroring the portable parts of the SafeClaw container setup.
#
# Core items (always applied, safe to re-run):
#   1. Shell aliases: c, cs, and a claude() wrapper (--fs -> --fork-session)
#   2. DX plugin from ykdojo/claude-code-tips (installs Xcode Command Line
#      Tools first if missing, since the plugin marketplace needs git)
#   3. settings.json: ENABLE_TOOL_SEARCH, DISABLE_AUTOUPDATER
#   4. settings.json: default model claude-opus-4-8
#   5. settings.json: attribution off (commit/pr/sessionUrl)
#   6. context-bar status line
#   7. settings.json: promptSuggestionEnabled false
#   8. .claude.json: hasAcceptedBypassPermissionsMode true, autoCompactEnabled false
#
# Opt-in items (disabled by default):
#   --playwright   install Node + Playwright MCP (browser automation)
#   --yt-dlp       install the yt-dlp binary + skill
#   --all          enable both opt-in items
#
# Usage:
#   ./setup-claude-env.sh                 # core only
#   ./setup-claude-env.sh --yt-dlp        # core + yt-dlp
#   ./setup-claude-env.sh --all           # core + everything
#
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

WANT_PLAYWRIGHT=0
WANT_YTDLP=0
for arg in "$@"; do
  case "$arg" in
    --playwright) WANT_PLAYWRIGHT=1 ;;
    --yt-dlp)     WANT_YTDLP=1 ;;
    --all)        WANT_PLAYWRIGHT=1; WANT_YTDLP=1 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; }

command -v claude >/dev/null || { echo "claude not found on PATH (~/.local/bin)"; exit 1; }
command -v jq >/dev/null     || { echo "jq is required"; exit 1; }

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_JSON="$HOME/.claude.json"
mkdir -p "$CLAUDE_DIR/scripts"

# --- 1. Shell aliases -------------------------------------------------------
setup_aliases() {
  log "Shell aliases (c / cs / --fs wrapper) -> ~/.zshrc"
  local zshrc="$HOME/.zshrc"
  touch "$zshrc"
  # Replace any previous block so re-runs don't duplicate.
  if grep -qF "# >>> claude-env >>>" "$zshrc"; then
    sed -i '' '/# >>> claude-env >>>/,/# <<< claude-env <<</d' "$zshrc"
  fi
  cat >> "$zshrc" <<'EOF'
# >>> claude-env >>>
alias c='claude'
alias cs='claude --dangerously-skip-permissions'
claude() {
  local args=()
  for arg in "$@"; do
    if [[ "$arg" == "--fs" ]]; then args+=("--fork-session"); else args+=("$arg"); fi
  done
  command claude "${args[@]}"
}
# <<< claude-env <<<
EOF
}

# --- 3-7. settings.json -----------------------------------------------------
setup_settings() {
  log "settings.json (tool search, model, attribution, status line, prompt suggestions)"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  local new tmp
  new='{
    "env": {"DISABLE_AUTOUPDATER":"1","ENABLE_TOOL_SEARCH":"true"},
    "model": "claude-opus-4-8",
    "attribution": {"commit":"","pr":"","sessionUrl":false},
    "promptSuggestionEnabled": false,
    "statusLine": {"type":"command","command":"~/.claude/scripts/context-bar.sh"}
  }'
  tmp=$(mktemp)
  jq --argjson new "$new" '. * $new' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

# --- 8. .claude.json flags --------------------------------------------------
setup_claude_json() {
  log ".claude.json (bypassPermissionsModeAccepted, autoCompactEnabled)"
  [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
  local tmp; tmp=$(mktemp)
  jq '. + {hasAcceptedBypassPermissionsMode: true, autoCompactEnabled: false}' \
    "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
}

# --- 6. context-bar status line script -------------------------------------
setup_statusline() {
  log "context-bar status line script"
  curl -fsSL -o "$CLAUDE_DIR/scripts/context-bar.sh" \
    https://raw.githubusercontent.com/ykdojo/claude-code-tips/main/scripts/context-bar.sh
  chmod +x "$CLAUDE_DIR/scripts/context-bar.sh"
}

# --- Xcode Command Line Tools (git, needed by the plugin marketplace) -------
ensure_clt() {
  if xcode-select -p >/dev/null 2>&1; then return 0; fi
  log "Installing Xcode Command Line Tools (git is a non-functional stub without them)"
  sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local label
  label=$(softwareupdate -l 2>/dev/null | sed -n 's/.*Label: \(Command Line Tools.*\)/\1/p' | sort -V | tail -1)
  if [ -n "$label" ]; then
    sudo softwareupdate -i "$label" --verbose || warn "CLT install failed; run 'xcode-select --install' manually"
  else
    warn "No Command Line Tools update found; run 'xcode-select --install' manually"
  fi
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
}

# --- 2. DX plugin -----------------------------------------------------------
setup_dx_plugin() {
  log "DX plugin (ykdojo/claude-code-tips)"
  claude plugin marketplace add https://github.com/ykdojo/claude-code-tips.git || true
  claude plugin install dx@ykdojo || true
}

# --- opt-in: yt-dlp ---------------------------------------------------------
setup_ytdlp() {
  log "yt-dlp binary + skill"
  mkdir -p "$HOME/.local/bin" "$CLAUDE_DIR/skills/yt-dlp"
  curl -fsSL -o "$HOME/.local/bin/yt-dlp" \
    https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
  chmod +x "$HOME/.local/bin/yt-dlp"
  curl -fsSL -o "$CLAUDE_DIR/skills/yt-dlp/SKILL.md" \
    https://raw.githubusercontent.com/ykdojo/safeclaw/main/setup/skills/yt-dlp/SKILL.md
}

# --- opt-in: Playwright MCP -------------------------------------------------
setup_playwright() {
  log "Playwright MCP (installs Node if missing, then a Chromium build)"
  if ! command -v node >/dev/null; then
    local nv arch tarball
    nv="v22.14.0"
    arch="x64"; [ "$(uname -m)" = "arm64" ] && arch="arm64"
    tarball="node-${nv}-darwin-${arch}.tar.gz"
    log "Installing Node ${nv} (${arch}) into ~/.local"
    curl -fsSL "https://nodejs.org/dist/${nv}/${tarball}" | tar -xz -C "$HOME/.local" --strip-components=1
  fi
  command -v npm >/dev/null || { warn "npm still not on PATH; Playwright aborted"; return 1; }
  npm install -g @playwright/mcp
  npx --yes playwright install chromium || warn "Chromium download failed; install it later with 'npx playwright install chromium'"
  claude mcp add playwright -- playwright-mcp --headless --browser chromium || true
}

setup_aliases
ensure_clt
setup_dx_plugin
setup_statusline
setup_settings
setup_claude_json
[ "$WANT_YTDLP" = 1 ]     && setup_ytdlp     || warn "yt-dlp (use --yt-dlp to enable)"
[ "$WANT_PLAYWRIGHT" = 1 ] && setup_playwright || warn "Playwright MCP (use --playwright to enable)"

log "Done. Open a new shell (or 'source ~/.zshrc') to pick up the aliases."
