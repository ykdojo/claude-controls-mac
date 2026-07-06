#!/usr/bin/env bash
#
# setup-computer-use.sh - enable "computer use" for an SSH-driven Claude Code on
# a Mac (step 11 in the README). Lets an interactive `claude` attached over SSH
# both see (screenshots) and control (mouse/keyboard) the Mac's desktop.
#
# Why it's needed: macOS ties Screen Recording + Accessibility to the GUI login
# session, so a process launched over SSH can't reach the display. This installs
# a LaunchAgent that keeps a `tmux` *server* alive *inside* the GUI session,
# pinned to a fixed socket. Because tmux is one server per socket, every session
# the `ic` helper (ic.sh) creates over SSH - `tmux -S <sock> new-session ...` -
# is born on that GUI-session server, so claude runs inside the GUI session and
# can reach the display. The Screen Recording + Accessibility grants go on the
# `claude` binary itself (see prerequisites).
# (claude is found on PATH via ~/.zshenv; see step 0 below.)
#
# Why tmux (not screen): macOS's system `screen` is the ancient 4.00.03 (2006),
# which can't render emoji, and even Homebrew screen 5.x replaces astral-plane
# emoji (📁, 🚀) with a placeholder. tmux renders them correctly. tmux's
# single-server model also removes screen's "spawn through an anchor" dance.
#
# Socket pinning: tmux's default socket lives under $TMPDIR, which on macOS
# differs between the GUI login session and an incoming SSH session - so the two
# would not share a server. We pin a fixed path ($SOCK) on every invocation
# (here and in ic.sh) so SSH and the GUI session always reach the same server.
#
# PREREQUISITES (one-time, manual - macOS blocks scripting these):
#   System Settings > Privacy & Security, grant to `claude` (easiest: trigger a
#   computer-use action once and macOS adds the `claude` entry, then toggle on):
#     - Screen Recording -> claude -> on
#     - Accessibility    -> claude -> on
#   Note: tied to the claude binary, so a claude update that moves its path can
#   drop the grants - re-grant if computer use breaks after an update.
#   Plus a Claude Pro/Max plan, with `claude` already logged in.
#
# Usage:
#   ./setup-computer-use.sh              # install
#   ./setup-computer-use.sh --uninstall  # remove the LaunchAgent + server
#
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

LABEL="com.boxclaude"
SESSION="cc"                 # the persistent anchor session that keeps the server alive
SOCK="/tmp/cc-tmux.sock"     # fixed socket shared by the GUI session and SSH (ic.sh)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLAUDE_JSON="$HOME/.claude.json"
GUI_UID=$(id -u)

# Prefer Homebrew tmux; fall back to anything on PATH. macOS does not ship tmux.
TMUX_BIN=$(command -v /opt/homebrew/bin/tmux 2>/dev/null \
  || command -v /usr/local/bin/tmux 2>/dev/null \
  || command -v tmux)
TMUX_DIR=$(dirname "$TMUX_BIN")

uninstall() {
  log "Removing LaunchAgent and tmux server (socket '$SOCK')"
  launchctl bootout "gui/$GUI_UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null || true
  log "Done. (The computer-use tool stays enabled in ~/.claude.json; remove it there if you want.)"
}

[ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }
[ "${1:-}" = "" ] || { echo "Unknown option: $1 (use --uninstall or no args)" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[ -x "$TMUX_BIN" ] || { echo "tmux not found (brew install tmux)"; exit 1; }

# 0. ~/.zshenv (read by *every* zsh, unlike ~/.zshrc which is interactive-only):
#    - PATH so `claude` is found when `ic` spawns it in a fresh tmux session.
#    - PATH so `ic`'s bare `tmux` calls resolve to the same brew tmux the anchor
#      runs (the socket path is fixed, but keep one binary to avoid surprises).
#    - LANG so claude's TUI renders UTF-8 (launchd gives the session no locale).
if ! grep -q '.local/bin' "$HOME/.zshenv" 2>/dev/null; then
  log "Adding ~/.local/bin to ~/.zshenv (needed for 'zsh -c claude')"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshenv"
fi
case "$TMUX_DIR" in
  /usr/bin|/bin|/usr/sbin|/sbin) : ;;  # system path, already on PATH
  *)
    if ! grep -q "$TMUX_DIR" "$HOME/.zshenv" 2>/dev/null; then
      log "Adding $TMUX_DIR to ~/.zshenv (so 'ic' uses the same tmux)"
      echo "export PATH=\"$TMUX_DIR:\$PATH\"" >> "$HOME/.zshenv"
    fi ;;
esac
if ! grep -q '^export LANG=' "$HOME/.zshenv" 2>/dev/null; then
  log "Adding LANG=en_US.UTF-8 to ~/.zshenv (UTF-8 rendering in the session)"
  echo 'export LANG=en_US.UTF-8' >> "$HOME/.zshenv"
fi

# 1. LaunchAgent: keep a tmux server alive in the GUI login session.
#    tmux daemonizes, so launchd cannot supervise the server process directly.
#    Instead the job runs a zsh wrapper that (re)creates the anchor session,
#    sets server options (C-a prefix like screen; no status bar), then blocks in
#    the foreground while the anchor lives. If the server dies the wrapper
#    returns and KeepAlive restarts it. A tmux server with zero sessions exits,
#    so the always-present `cc` anchor is what keeps it alive between ic sessions.
log "Installing LaunchAgent ($PLIST)"
mkdir -p "$HOME/Library/LaunchAgents"
#    The after-load-buffer hook mirrors tmux buffers into the Mac pasteboard:
#    claude's /copy runs `tmux load-buffer` (it never calls pbcopy), so without
#    this the copied text is invisible to `clip get` from the source Mac.
WRAP="$TMUX_BIN -S $SOCK has-session -t $SESSION 2>/dev/null || $TMUX_BIN -S $SOCK new-session -d -s $SESSION; $TMUX_BIN -S $SOCK set -g prefix C-a; $TMUX_BIN -S $SOCK set -g prefix2 C-b; $TMUX_BIN -S $SOCK set -g status off; $TMUX_BIN -S $SOCK set-hook -g after-load-buffer 'run-shell \"$TMUX_BIN -S $SOCK save-buffer - | pbcopy\"'; while $TMUX_BIN -S $SOCK has-session -t $SESSION 2>/dev/null; do sleep 5; done"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>-c</string><string>$WRAP</string></array>
  <key>EnvironmentVariables</key><dict><key>SHELL</key><string>/bin/zsh</string><key>TERM</key><string>xterm-256color</string><key>LANG</key><string>en_US.UTF-8</string></dict>
  <key>WorkingDirectory</key><string>$HOME</string>
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
# The server is up once the anchor session answers on the pinned socket.
up=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then up=1; break; fi
  sleep 1
done
if [ "$up" = 1 ]; then
  log "tmux anchor session '$SESSION' is running (socket $SOCK)"
else
  warn "tmux anchor '$SESSION' not up yet - check: launchctl print gui/$GUI_UID/$LABEL"
fi

# 2. Enable the built-in computer-use tool for the home project (skips /mcp menu).
#    enabledMcpServers is per-project, so this must match where claude runs - the
#    LaunchAgent's WorkingDirectory above pins the session to $HOME so they agree.
log "Enabling the computer-use tool in $CLAUDE_JSON (project: $HOME)"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
tmp=$(mktemp)
jq --arg p "$HOME" \
  '.projects[$p].enabledMcpServers = (((.projects[$p].enabledMcpServers // []) + ["computer-use"]) | unique)' \
  "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"

log "Computer use configured."
echo
echo "Next:"
echo "  1. One-time grants (if not done) in System Settings > Privacy & Security,"
echo "     for the 'claude' entry (trigger a computer-use action once to add it):"
echo "       Screen Recording -> claude -> on"
echo "       Accessibility    -> claude -> on"
echo "  2. On your Mac, install the 'ic' helper and run claude (needs Pro/Max):"
echo "       curl -fsSL https://raw.githubusercontent.com/ykdojo/claude-controls-mac/main/ic.sh -o ~/.local/bin/ic && chmod +x ~/.local/bin/ic"
echo "       export IC_BOX=<user>@<host>.local   # then:  ic   (new)   ic -c   ic ls   ic a <id>"
