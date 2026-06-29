#!/usr/bin/env bash
#
# setup-computer-use.sh - enable "computer use" for an SSH-driven Claude Code on
# a Mac (step 11 in the README). Lets an interactive `claude` attached over SSH
# both see (screenshots) and control (mouse/keyboard) the Mac's desktop.
#
# Why it's needed: macOS ties Screen Recording + Accessibility to the GUI login
# session, so a process launched over SSH can't reach the display. This installs
# a LaunchAgent that keeps a `screen` session ("cc") alive *inside* the GUI
# session; `claude` runs inside it as a child of the granted `screen` binary, so
# computer use inherits the permissions and the display. Attach over SSH with
# `screen -r cc`.
#
# PREREQUISITES (one-time, manual - macOS blocks scripting these):
#   System Settings > Privacy & Security:
#     - Screen Recording -> + -> /usr/bin/screen -> on
#     - Accessibility    -> + -> /usr/bin/screen -> on
#   Plus a Claude Pro/Max plan, with `claude` already logged in.
#
# Usage:
#   ./setup-computer-use.sh              # install
#   ./setup-computer-use.sh --uninstall  # remove the LaunchAgent + session
#
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

LABEL="com.boxclaude"
SESSION="cc"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLAUDE_JSON="$HOME/.claude.json"
GUI_UID=$(id -u)

uninstall() {
  log "Removing LaunchAgent and screen session '$SESSION'"
  launchctl bootout "gui/$GUI_UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  /usr/bin/screen -S "$SESSION" -X quit 2>/dev/null || true
  log "Done. (The computer-use tool stays enabled in ~/.claude.json; remove it there if you want.)"
}

[ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }
[ "${1:-}" = "" ] || { echo "Unknown option: $1 (use --uninstall or no args)" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[ -x /usr/bin/screen ] || { echo "/usr/bin/screen not found"; exit 1; }

# 0. ~/.zshenv (read by *every* zsh, unlike ~/.zshrc which is interactive-only):
#    - PATH so `zsh -c claude` (used by the attach alias) finds claude.
#    - LANG so claude's TUI renders UTF-8 (launchd gives the session no locale).
if ! grep -q '.local/bin' "$HOME/.zshenv" 2>/dev/null; then
  log "Adding ~/.local/bin to ~/.zshenv (needed for 'zsh -c claude')"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshenv"
fi
if ! grep -q '^export LANG=' "$HOME/.zshenv" 2>/dev/null; then
  log "Adding LANG=en_US.UTF-8 to ~/.zshenv (UTF-8 rendering in the session)"
  echo 'export LANG=en_US.UTF-8' >> "$HOME/.zshenv"
fi

# 1. LaunchAgent: keep a `screen` session alive in the GUI login session.
#    `screen -D -m` runs screen in the foreground as the launchd job's main
#    process, so launchd doesn't reap a daemonized child; KeepAlive respawns it.
log "Installing LaunchAgent ($PLIST)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/screen</string><string>-U</string><string>-D</string><string>-m</string><string>-S</string><string>$SESSION</string><string>/bin/zsh</string></array>
  <key>EnvironmentVariables</key><dict><key>SHELL</key><string>/bin/zsh</string><key>TERM</key><string>xterm-256color</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
</dict></plist>
PLISTEOF
plutil -lint "$PLIST" >/dev/null
# Load only if it isn't already loaded. Re-bootstrapping on every run trips
# launchd's restart throttle and the session takes ~10s to reappear. To apply a
# changed plist, run --uninstall first.
if launchctl print "gui/$GUI_UID/$LABEL" >/dev/null 2>&1; then
  log "LaunchAgent already loaded (run --uninstall first to apply plist changes)"
else
  launchctl bootstrap "gui/$GUI_UID" "$PLIST" 2>/dev/null \
    || warn "Could not load the LaunchAgent - run this while logged into the Mac's GUI session."
fi
# The session is up when the launchd job (the foreground `screen -D -m`) is
# running - more reliable here than parsing `screen -ls`.
up=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if launchctl print "gui/$GUI_UID/$LABEL" 2>/dev/null | grep -q "state = running"; then up=1; break; fi
  sleep 1
done
if [ "$up" = 1 ]; then
  log "screen session '$SESSION' is running"
else
  warn "screen session '$SESSION' not up yet - check: launchctl print gui/$GUI_UID/$LABEL"
fi

# 2. Enable the built-in computer-use tool for the home project (skips /mcp menu).
log "Enabling the computer-use tool in $CLAUDE_JSON (project: $HOME)"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
tmp=$(mktemp)
jq --arg p "$HOME" \
  '.projects[$p].enabledMcpServers = (((.projects[$p].enabledMcpServers // []) + ["computer-use"]) | unique)' \
  "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"

log "Computer use configured."
echo
echo "Next:"
echo "  1. One-time grants (if not done) in System Settings > Privacy & Security:"
echo "       Screen Recording -> + -> /usr/bin/screen -> on"
echo "       Accessibility    -> + -> /usr/bin/screen -> on"
echo "  2. From your Mac, attach and run claude (needs Pro/Max):"
echo "       ssh <user>@<host>.local -t 'screen -r $SESSION || screen -S $SESSION -X screen claude; screen -r $SESSION'"
