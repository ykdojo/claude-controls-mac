#!/usr/bin/env bash
#
# ic - "isolated claude": run Claude Code on the box over SSH, with computer use.
#
# Each `ic` invocation creates its own GUI-session `tmux` session running
# `claude` (so multiple independent conversations can run at once), then attaches
# to it. The persistent `cc` anchor (installed by setup-computer-use.sh) keeps a
# tmux *server* alive inside the GUI login session on a fixed socket; because
# tmux is one server per socket, every session created here lands on that server
# and inherits the GUI login session - which is what makes computer use work
# over SSH. No "spawn through the anchor" indirection is needed (unlike screen).
#
# Usage:
#   ic                 # new claude session
#   ic -c              # forwards to: claude -c   (continue)
#   ic -r              # forwards to: claude -r   (resume picker)
#   ic <claude flags>  # any other args forward to claude
#   ic ls              # list live ic-* sessions (state, age, proc, conversation)
#   ic attach <id>     # attach a running session (alias: ic a)
#
# Config: set IC_BOX to <user>@<host> (default below). IC_SOCK overrides the
# tmux socket path (must match setup-computer-use.sh; default below).
#
set -euo pipefail

BOX="${IC_BOX:-yk2@newmacbook.local}"
SOCK="${IC_SOCK:-/tmp/cc-tmux.sock}"   # fixed tmux socket (matches setup-computer-use.sh)

usage() {
  cat <<'EOF'
ic - "isolated claude": run Claude Code on the box over SSH, with computer use.

All claude sessions run with --dangerously-skip-permissions (the box is an
isolated sandbox, so prompts are auto-approved); ic rc spawns phone sessions
with --permission-mode bypassPermissions for the same reason.

Usage:
  ic                 new claude session
  ic -c              continue the most recent conversation (forwards: claude -c)
  ic -r              resume picker (forwards: claude -r)
  ic <claude flags>  any other args forward to claude
  ic sh              a plain shell on the box (no claude; alias: ic shell)
  ic rc              Remote Control: drive the box from your phone
                       (runs claude remote-control; extra args forward to it;
                        alias: ic remote-control)
  ic history         stored conversations: count, location, recent (alias: hist)
  ic ls              list live sessions (state, age, proc, conversation)
  ic attach <id>     attach a running session (alias: ic a)
  ic kill <id>       kill a session (alias: ic k); 'ic kill all' kills all
  ic kill except <id>...   kill all sessions except the listed ones
  ic -h | --help     this help

Config: set IC_BOX to <user>@<host> (default: yk2@newmacbook.local).
Detach from a session with Ctrl-A then D; reattach with: ic attach <id>
EOF
}

# Normalize a session id: accept "ic-1234", "1234", and map to full name.
norm() { case "$1" in ic-*) printf '%s' "$1";; *) printf 'ic-%s' "$1";; esac; }

case "${1:-}" in
  -h|--help|help)
    usage
    ;;

  ls)
    # Each live ic-* tmux session: attach state, age, what's running (interactive
    # claude / claude remote-control / a plain shell), and the conversation's AI
    # title (the same one /resume shows; falls back to the last prompt). Starting
    # from each session's pane pid, the claude descendant is matched to its
    # conversation via ~/.claude/sessions/<pid>.json (records the sessionId), then
    # to the transcript at ~/.claude/projects/<proj>/<sessionId>.jsonl.
    ssh "$BOX" "SOCK='$SOCK' bash -s" <<'RSCRIPT'
SOCK="${SOCK:-/tmp/cc-tmux.sock}"
proj=$(echo "$HOME" | sed 's:/:-:g'); pdir="$HOME/.claude/projects/$proj"; sdir="$HOME/.claude/sessions"
sessions=$(tmux -S "$SOCK" list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null | grep '^ic-')
[ -z "$sessions" ] && { echo "No live ic sessions."; exit 0; }
now=$(date +%s)
fmt_age() {
  t="$1"; [ -z "$t" ] && { echo "?"; return; }; [ "$t" -lt 0 ] && t=0
  if [ "$t" -ge 86400 ]; then echo "$((t/86400))d$(((t%86400)/3600))h"
  elif [ "$t" -ge 3600 ]; then echo "$((t/3600))h$(((t%3600)/60))m"
  elif [ "$t" -ge 60 ]; then echo "$((t/60))m"; else echo "${t}s"; fi
}
printf "%-20s %-9s %-7s %-10s %s\n" "SESSION" "STATE" "AGE" "PROC" "CONVERSATION"
printf '%s\n' "$sessions" | while IFS='|' read -r name attached created; do
  state=Detached; [ "${attached:-0}" -ge 1 ] 2>/dev/null && state=Attached
  if [ -n "$created" ]; then age=$(fmt_age "$((now - created))"); else age="?"; fi
  # walk the session's pane process tree (a few levels) to find claude
  pids=$(tmux -S "$SOCK" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null)"; done
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null)"; done
  proc=shell; cpid=
  for p in $pids; do case "$(ps -o command= -p "$p" 2>/dev/null)" in *"claude remote-control"*) proc="claude-rc"; break;; esac; done
  # the real claude pid is the descendant that has a sessions/<pid>.json (the
  # shell wrapper also carries "claude" in its argv, so don't match on that)
  if [ "$proc" != claude-rc ]; then
    for p in $pids; do [ -f "$sdir/$p.json" ] && { proc=claude; cpid=$p; break; }; done
  fi
  conv=""
  if [ "$proc" = claude ]; then
    sid=$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$sdir/$cpid.json")
    jf="$pdir/$sid.jsonl"
    [ -f "$jf" ] && conv=$(jq -rs '(last(.[]|select(.type=="ai-title")|.aiTitle)) // (last(.[]|select(.type=="last-prompt")|.lastPrompt)) // ""' "$jf" 2>/dev/null | tr "\n\t" "  " | sed "s/  */ /g" | cut -c1-50)
  elif [ "$proc" = claude-rc ]; then conv="(remote-control host)"; fi
  printf "%-20s %-9s %-7s %-10s %s\n" "$name" "$state" "$age" "$proc" "$conv"
done
echo ""
echo "attach: ic attach <id>   (alias: ic a; detach: Ctrl-A then D)"
echo "kill:   ic kill <id>     (alias: ic k; 'ic kill all' kills all; 'ic kill except <id>...' keeps only those)"
RSCRIPT
    ;;

  attach|a)
    id="${2:-}"
    if [ -z "$id" ]; then
      echo "Usage: ic attach <id>   (see 'ic ls' for live sessions)"; exit 1
    fi
    sess="$(norm "$id")"
    exec ssh "$BOX" -t "tmux -S $SOCK attach -t $sess"
    ;;

  sh|shell)
    # A plain shell in a fresh GUI-session tmux session (no claude) - persists and
    # has GUI access (screencapture etc. work), unlike a plain `ssh` shell.
    sess="ic-sh-$(date +%H%M%S)-$$"
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess zsh"
    ;;

  rc|remote-control)
    # Remote Control: drive the box's claude from your phone (claude.ai/code or
    # the mobile app). Runs in a GUI-session tmux session so it can read the login
    # token (the Keychain is only reachable inside the GUI session). Extra args
    # forward to `claude remote-control` (e.g. --spawn=worktree --capacity=N).
    shift
    sess="ic-rc-$(date +%H%M%S)-$$"
    # bypassPermissions: phone-spawned sessions auto-approve too (isolated box).
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess \"claude remote-control --permission-mode bypassPermissions $*\""
    ;;

  history|hist)
    # Overview of stored conversations for the box's project ($HOME). Each ic
    # session runs in $HOME, so they all collect in one project dir.
    ssh "$BOX" 'bash -s' <<'RSCRIPT'
proj=$(echo "$HOME" | sed 's:/:-:g')
d="$HOME/.claude/projects/$proj"
ls "$d"/*.jsonl >/dev/null 2>&1 || { echo "No conversations yet in $d"; exit 0; }
n=$(ls "$d"/*.jsonl | wc -l | tr -d ' ')
size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
echo "Conversations (project $HOME)"
echo "  $d"
echo "  $n total · ${size:-?}"
echo ""
echo "  recent:"
ls -t "$d"/*.jsonl | head -10 | while read -r f; do
  id=$(basename "$f" .jsonl)
  when=$(stat -f '%Sm' -t '%b %d %H:%M' "$f" 2>/dev/null)
  msgs=$(wc -l < "$f" | tr -d ' ')
  prev=$(jq -rs '[.[]|select(.type=="user")][0].message.content
          | if type=="array" then (map(select(.type=="text").text)|join(" ")) else . end' \
          "$f" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-54)
  printf "  %.8s  %-12s  %4s msg  %s\n" "$id" "$when" "$msgs" "$prev"
done
echo ""
echo "  open/continue:  ic -r   (resume picker, has search)"
echo ""
echo "  to search/read, grep or jq the files directly. each is JSONL, one JSON"
echo "  object per line. key fields:"
echo "    .type            user | assistant | system | attachment | ...  (filter user/assistant for messages)"
echo "    .message.content string (user) or array of {type,text,...} blocks (assistant)"
echo "    .timestamp  .cwd  .gitBranch  .sessionId"
echo "  e.g.  ssh <box> 'grep -l TERM $d/*.jsonl'"
echo "        ssh <box> \"jq -rs '[.[]|select(.type==\\\"user\\\")][].message.content' FILE\""
RSCRIPT
    ;;

  kill|k)
    id="${2:-}"
    if [ "$id" = "all" ]; then
      ssh "$BOX" "tmux -S $SOCK list-sessions -F '#{session_name}' 2>/dev/null | grep '^ic-' | xargs -I{} tmux -S $SOCK kill-session -t {} 2>/dev/null || true"
      echo "Killed all ic sessions."
      exit 0
    fi
    if [ "$id" = "except" ]; then
      shift 2
      if [ $# -eq 0 ]; then
        echo "Usage: ic kill except <id> [<id>...]   (kills all other sessions; see 'ic ls')"; exit 1
      fi
      keep=""
      for k in "$@"; do keep="$keep $(norm "$k")"; done
      ssh "$BOX" "SOCK='$SOCK' KEEP='$keep' bash -s" <<'RSCRIPT'
SOCK="${SOCK:-/tmp/cc-tmux.sock}"
live=$(tmux -S "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | grep '^ic-')
# refuse to run on a typo: every keep id must match a live session
for k in $KEEP; do
  printf '%s\n' "$live" | grep -qx "$k" || { echo "ic: keep target $k not found; nothing killed" >&2; exit 1; }
done
n=0
for s in $live; do
  case " $KEEP " in *" $s "*) echo "Kept   $s"; continue;; esac
  tmux -S "$SOCK" kill-session -t "$s" 2>/dev/null && { echo "Killed $s"; n=$((n+1)); }
done
echo "Killed $n session(s)."
RSCRIPT
      exit 0
    fi
    if [ -z "$id" ]; then
      echo "Usage: ic kill <id> | all | except <id>...   (see 'ic ls' for live sessions)"; exit 1
    fi
    sess="$(norm "$id")"
    ssh "$BOX" "tmux -S $SOCK kill-session -t $sess 2>/dev/null || true"
    echo "Killed $sess."
    ;;

  *)
    # New session: create `claude <args>` in a fresh GUI-session tmux session and
    # attach in one step. Only simple flags are forwarded (no prompt forwarding),
    # so this stays quote-safe.
    # --dangerously-skip-permissions: the box is a throwaway sandbox, so
    # auto-approve everything (no permission prompts).
    sess="ic-$(date +%H%M%S)-$$"
    exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $sess \"claude --dangerously-skip-permissions $*\""
    ;;
esac
