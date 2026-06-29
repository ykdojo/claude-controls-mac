#!/usr/bin/env bash
#
# setup-claude-env.sh - configure a Claude Code environment on this Mac,
# mirroring the portable parts of the SafeClaw container setup.
#
# Items (1-8 are the core defaults; 9-10 are opt-in, off by default):
#   1. Shell aliases: c, cs, and a claude() wrapper (--fs -> --fork-session)
#   2. DX plugin from ykdojo/claude-code-tips (installs Xcode Command Line
#      Tools first if missing, since the plugin marketplace needs git)
#   3. settings.json: ENABLE_TOOL_SEARCH, DISABLE_AUTOUPDATER
#   4. settings.json: default model claude-opus-4-8
#   5. settings.json: attribution off (commit/pr/sessionUrl)
#   6. context-bar status line
#   7. settings.json: promptSuggestionEnabled false
#   8. .claude.json: hasAcceptedBypassPermissionsMode true, autoCompactEnabled false
#   9. Playwright MCP (installs Node + a headless Chromium build)
#  10. yt-dlp binary + skill
#
# Selection:
#   - Run at a terminal with no flags -> interactive checklist (toggle any item;
#     core pre-checked, opt-ins unchecked).
#   - Piped / non-interactive with no flags -> core only (never hangs over SSH).
#   - Flags skip the menu:
#       --playwright   enable item 9
#       --yt-dlp       enable item 10
#       --all          enable items 9 and 10
#       --core         core only, no prompt
#
# Usage:
#   ./setup-claude-env.sh                 # interactive menu (terminal) / core only (piped)
#   ./setup-claude-env.sh --core          # core only, no prompt
#   ./setup-claude-env.sh --all           # core + every opt-in, no prompt
#
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; }

# Item labels (index 0..9 = items 1..10).
LABELS=(
  "Shell aliases (c / cs / --fs)"
  "DX plugin (ykdojo/claude-code-tips)"
  "Tool search + disable auto-updater"
  "Default model: Opus 4.8"
  "Attribution off (commit / PR / sessionUrl)"
  "context-bar status line"
  "Prompt suggestions off"
  "Bypass + autocompact flags"
  "Playwright MCP (heavy: Node + Chromium)"
  "yt-dlp binary + skill"
)
# Default selection: core (1-8) on, opt-ins (9-10) off.
SEL=(1 1 1 1 1 1 1 1 0 0)

FLAGS_GIVEN=0
for arg in "$@"; do
  case "$arg" in
    --playwright) SEL[8]=1; FLAGS_GIVEN=1 ;;
    --yt-dlp)     SEL[9]=1; FLAGS_GIVEN=1 ;;
    --all)        SEL[8]=1; SEL[9]=1; FLAGS_GIVEN=1 ;;
    --core)       FLAGS_GIVEN=1 ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

interactive_menu() {
  while true; do
    echo
    echo "Claude Code environment - choose what to install:"
    echo
    local i mark
    for i in "${!LABELS[@]}"; do
      mark="[ ]"; [ "${SEL[$i]}" = 1 ] && mark="[x]"
      printf "  %2d. %s %s\n" "$((i + 1))" "$mark" "${LABELS[$i]}"
    done
    echo
    printf "Toggle by number (space-separated, e.g. \"9 10\"), or Enter to accept: "
    local input n idx
    read -r input
    [ -z "$input" ] && break
    for n in $input; do
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#LABELS[@]}" ]; then
        idx=$((n - 1))
        [ "${SEL[$idx]}" = 1 ] && SEL[$idx]=0 || SEL[$idx]=1
      fi
    done
  done
}

if [ "$FLAGS_GIVEN" = 0 ]; then
  if [ -t 0 ]; then
    interactive_menu
  else
    echo "(non-interactive, no flags: installing core only - pass --all/--yt-dlp/--playwright for opt-ins)"
  fi
fi

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

# --- 6 (part). context-bar status line script ------------------------------
setup_statusline_script() {
  curl -fsSL -o "$CLAUDE_DIR/scripts/context-bar.sh" \
    https://raw.githubusercontent.com/ykdojo/claude-code-tips/main/scripts/context-bar.sh
  chmod +x "$CLAUDE_DIR/scripts/context-bar.sh"
}

# --- 3-7. settings.json (each key gated on its own item) --------------------
apply_settings() {
  local obj='{}'
  [ "${SEL[2]}" = 1 ] && obj=$(jq -n --argjson o "$obj" '$o + {env:{DISABLE_AUTOUPDATER:"1",ENABLE_TOOL_SEARCH:"true"}}')
  [ "${SEL[3]}" = 1 ] && obj=$(jq -n --argjson o "$obj" '$o + {model:"claude-opus-4-8"}')
  [ "${SEL[4]}" = 1 ] && obj=$(jq -n --argjson o "$obj" '$o + {attribution:{commit:"",pr:"",sessionUrl:false}}')
  if [ "${SEL[5]}" = 1 ]; then
    setup_statusline_script
    obj=$(jq -n --argjson o "$obj" '$o + {statusLine:{type:"command",command:"~/.claude/scripts/context-bar.sh"}}')
  fi
  [ "${SEL[6]}" = 1 ] && obj=$(jq -n --argjson o "$obj" '$o + {promptSuggestionEnabled:false}')
  if [ "$obj" != '{}' ]; then
    log "settings.json (selected keys)"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    local tmp; tmp=$(mktemp)
    jq --argjson new "$obj" '. * $new' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  fi
}

# --- 8. .claude.json flags --------------------------------------------------
setup_claude_json() {
  log ".claude.json (hasAcceptedBypassPermissionsMode, autoCompactEnabled)"
  [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
  local tmp; tmp=$(mktemp)
  jq '. + {hasAcceptedBypassPermissionsMode: true, autoCompactEnabled: false}' \
    "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
}

# --- 9. Playwright MCP ------------------------------------------------------
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
  command -v npm >/dev/null || { warn "npm still not on PATH; Playwright aborted"; return 0; }
  npm install -g @playwright/mcp
  npx --yes playwright install chromium || warn "Chromium download failed; install it later with 'npx playwright install chromium'"
  claude mcp add playwright -- playwright-mcp --headless --browser chromium || true
}

# --- 10. yt-dlp -------------------------------------------------------------
setup_ytdlp() {
  log "yt-dlp binary + skill"
  mkdir -p "$HOME/.local/bin" "$CLAUDE_DIR/skills/yt-dlp"
  curl -fsSL -o "$HOME/.local/bin/yt-dlp" \
    https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
  chmod +x "$HOME/.local/bin/yt-dlp"
  curl -fsSL -o "$CLAUDE_DIR/skills/yt-dlp/SKILL.md" \
    https://raw.githubusercontent.com/ykdojo/safeclaw/main/setup/skills/yt-dlp/SKILL.md
}

# --- run the selected items -------------------------------------------------
[ "${SEL[0]}" = 1 ] && setup_aliases
if [ "${SEL[1]}" = 1 ]; then ensure_clt; setup_dx_plugin; fi
apply_settings                                   # items 3-7, internally gated
[ "${SEL[7]}" = 1 ] && setup_claude_json
if [ "${SEL[8]}" = 1 ]; then setup_playwright; fi
[ "${SEL[9]}" = 1 ] && setup_ytdlp

log "Done. Open a new shell (or 'source ~/.zshrc') to pick up the aliases."
