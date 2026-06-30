#!/usr/bin/env bash
#
# ic - "isolated claude": run Claude Code on the box over SSH, with computer use.
#
# Each `ic` invocation spawns its own GUI-session `screen` session running
# `claude` (so multiple independent conversations can run at once), then attaches
# to it. Sessions are spawned *through* the persistent `cc` anchor (installed by
# setup-computer-use.sh) so they inherit the GUI login session - which is what
# makes computer use work over SSH.
#
# Usage:
#   ic                 # new claude session
#   ic -c              # forwards to: claude -c   (continue)
#   ic -r              # forwards to: claude -r   (resume picker)
#   ic <claude flags>  # any other args forward to claude
#   ic ls              # list live ic-* sessions (state, age, proc, last msg)
#   ic attach <id>     # attach a running session (alias: ic a)
#
# Config: set IC_BOX to <user>@<host> (default below).
#
set -euo pipefail

BOX="${IC_BOX:-yk2@newmacbook.local}"
ANCHOR="cc"   # the persistent GUI-session screen session (from the LaunchAgent)

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
                       (runs claude remote-control; extra args forward to it)
  ic history         stored conversations: count, location, recent (alias: hist)
  ic ls              list live sessions (state, age, proc, last msg)
  ic attach <id>     attach a running session (alias: ic a)
  ic kill <id>       kill a session (alias: ic k); 'ic kill all' kills all
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
    # Each live ic-* screen session: attach state, age, what's running (interactive
    # claude / claude remote-control / a plain shell), and the conversation's last
    # user message. The screen daemon's claude descendant is matched to its
    # conversation via ~/.claude/sessions/<pid>.json (records the sessionId), then
    # to the transcript at ~/.claude/projects/<proj>/<sessionId>.jsonl.
    ssh "$BOX" 'bash -s' <<'RSCRIPT'
proj=$(echo "$HOME" | sed 's:/:-:g'); pdir="$HOME/.claude/projects/$proj"; sdir="$HOME/.claude/sessions"
screen -wipe >/dev/null 2>&1
out=$(screen -ls 2>/dev/null | grep -E "[0-9]+\.ic-[A-Za-z0-9_-]+")
[ -z "$out" ] && { echo "No live ic sessions."; exit 0; }
fmt_age() {
  e="$1"; [ -z "$e" ] && { echo "?"; return; }; d=0
  case "$e" in *-*) d=${e%%-*}; e=${e#*-};; esac
  n=$(printf '%s' "$e" | tr -cd ':' | wc -c | tr -d ' ')
  if [ "$n" = 2 ]; then h=${e%%:*}; r=${e#*:}; m=${r%:*}; s=${r#*:}; else h=0; m=${e%:*}; s=${e#*:}; fi
  t=$(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$s ))
  if [ $t -ge 86400 ]; then echo "$((t/86400))d$(((t%86400)/3600))h"
  elif [ $t -ge 3600 ]; then echo "$((t/3600))h$(((t%3600)/60))m"
  elif [ $t -ge 60 ]; then echo "$((t/60))m"; else echo "${t}s"; fi
}
printf "%-20s %-9s %-7s %-10s %s\n" "SESSION" "STATE" "AGE" "PROC" "CONVERSATION (last msg)"
printf '%s\n' "$out" | while IFS= read -r line; do
  entry=$(printf '%s' "$line" | grep -oE "[0-9]+\.ic-[A-Za-z0-9_-]+")
  spid=${entry%%.*}; name=${entry#*.}
  state=Detached; printf '%s' "$line" | grep -q "(Attached)" && state=Attached
  age=$(fmt_age "$(ps -o etime= -p "$spid" 2>/dev/null | tr -d ' ')")
  # collect the screen daemon's descendants (a few levels)
  pids=$(pgrep -P "$spid" 2>/dev/null)
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null)"; done
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null)"; done
  proc=shell; cpid=
  for p in $pids; do case "$(ps -o command= -p "$p" 2>/dev/null)" in *"claude remote-control"*) proc="claude-rc"; break;; esac; done
  # the real claude pid is the descendant that has a sessions/<pid>.json (the
  # login/screen wrappers also carry "claude" in their argv, so don't match on that)
  if [ "$proc" != claude-rc ]; then
    for p in $pids; do [ -f "$sdir/$p.json" ] && { proc=claude; cpid=$p; break; }; done
  fi
  conv=""
  if [ "$proc" = claude ]; then
    sid=$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$sdir/$cpid.json")
    jf="$pdir/$sid.jsonl"
    [ -f "$jf" ] && conv=$(jq -rs '[.[]|select(.type=="user")|.message.content|if type=="array" then (map(select(.type=="text").text)|join(" ")) else . end|select(.!=null and .!="")]|last // ""' "$jf" 2>/dev/null | tr "\n\t" "  " | sed "s/  */ /g" | cut -c1-46)
  elif [ "$proc" = claude-rc ]; then conv="(remote-control host)"; fi
  printf "%-20s %-9s %-7s %-10s %s\n" "$name" "$state" "$age" "$proc" "$conv"
done
RSCRIPT
    ;;

  attach|a)
    id="${2:-}"
    if [ -z "$id" ]; then
      echo "Usage: ic attach <id>   (see 'ic ls' for live sessions)"; exit 1
    fi
    sess="$(norm "$id")"
    exec ssh "$BOX" -t "screen -U -x $sess"
    ;;

  sh|shell)
    # A plain shell in a fresh GUI-session screen (no claude) - persists and has
    # GUI access (screencapture etc. work), unlike a plain `ssh` shell.
    sess="ic-sh-$(date +%H%M%S)-$$"
    ssh "$BOX" "screen -S $ANCHOR -X screen zsh -c 'screen -U -dmS $sess zsh'; \
                for _ in \$(seq 25); do screen -ls 2>/dev/null | grep -q $sess && break; sleep 0.2; done"
    exec ssh "$BOX" -t "screen -U -x $sess"
    ;;

  rc)
    # Remote Control: drive the box's claude from your phone (claude.ai/code or
    # the mobile app). Runs in a GUI-session screen so it can read the login
    # token (the Keychain is only reachable inside the GUI session). Extra args
    # forward to `claude remote-control` (e.g. --spawn=worktree --capacity=N).
    shift
    sess="ic-rc-$(date +%H%M%S)-$$"
    # bypassPermissions: phone-spawned sessions auto-approve too (isolated box).
    ssh "$BOX" "screen -S $ANCHOR -X screen zsh -c 'screen -U -dmS $sess claude remote-control --permission-mode bypassPermissions $*'; \
                for _ in \$(seq 25); do screen -ls 2>/dev/null | grep -q $sess && break; sleep 0.2; done"
    exec ssh "$BOX" -t "screen -U -x $sess"
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
      ssh "$BOX" 'for s in $(screen -ls 2>/dev/null | grep -oE "ic-[A-Za-z0-9_-]+"); do screen -S "$s" -X quit; done; screen -wipe >/dev/null 2>&1 || true'
      echo "Killed all ic sessions."
      exit 0
    fi
    if [ -z "$id" ]; then
      echo "Usage: ic kill <id> | all   (see 'ic ls' for live sessions)"; exit 1
    fi
    sess="$(norm "$id")"
    ssh "$BOX" "screen -S $sess -X quit 2>/dev/null; screen -wipe >/dev/null 2>&1 || true"
    echo "Killed $sess."
    ;;

  *)
    # New session: spawn `claude <args>` in a fresh GUI-session screen via the
    # anchor, wait for it to come up, then attach. Only simple flags are
    # forwarded (no prompt forwarding), so this stays quote-safe.
    # --dangerously-skip-permissions: the box is a throwaway sandbox, so
    # auto-approve everything (no permission prompts).
    sess="ic-$(date +%H%M%S)-$$"
    ssh "$BOX" "screen -S $ANCHOR -X screen zsh -c 'screen -U -dmS $sess claude --dangerously-skip-permissions $*'; \
                for _ in \$(seq 25); do screen -ls 2>/dev/null | grep -q $sess && break; sleep 0.2; done"
    exec ssh "$BOX" -t "screen -U -x $sess"
    ;;
esac
