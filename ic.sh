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
#   ic ls              # list live ic-* sessions on the box
#   ic a [id]          # attach a running session (alias: ic attach)
#                      #   no id + exactly one session -> attaches it
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
  ic search <term>   search stored conversations for <term>
  ic ls              list live sessions on the box
  ic a [id]          attach a running session (alias: ic attach)
                       no id + exactly one session -> attaches it
  ic kill [id]       kill a session (alias: ic k); 'ic kill all' kills all;
                       no id + exactly one session -> kills it
  ic -h | --help     this help

Config: set IC_BOX to <user>@<host> (default: yk2@newmacbook.local).
Detach from a session with Ctrl-A then D; reattach with: ic a <id>
EOF
}

# Normalize a session id: accept "ic-1234", "1234", and map to full name.
norm() { case "$1" in ic-*) printf '%s' "$1";; *) printf 'ic-%s' "$1";; esac; }

# List ic-* session names on the box (one per line), wiping dead ones first.
list_sessions() {
  ssh "$BOX" 'screen -wipe >/dev/null 2>&1; screen -ls 2>/dev/null | grep -oE "ic-[A-Za-z0-9_-]+"' || true
}

case "${1:-}" in
  -h|--help|help)
    usage
    ;;

  ls)
    s="$(list_sessions)"
    if [ -z "$s" ]; then echo "No live ic sessions."; else echo "$s"; fi
    ;;

  a|attach)
    id="${2:-}"
    if [ -z "$id" ]; then
      s="$(list_sessions)"
      n="$(printf '%s\n' "$s" | grep -c . || true)"
      if [ "$n" -eq 0 ]; then echo "No live ic sessions. Start one with: ic"; exit 1; fi
      if [ "$n" -gt 1 ]; then
        echo "Multiple sessions - pick one with 'ic a <id>':"; echo "$s"; exit 1
      fi
      sess="$s"
    else
      sess="$(norm "$id")"
    fi
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
echo "  open/continue:  ic -r            (resume picker)"
echo "  search:         ic search <term>"
RSCRIPT
    ;;

  search)
    shift
    [ $# -gt 0 ] || { echo "usage: ic search <term>"; exit 1; }
    ssh "$BOX" "bash -s -- $(printf '%q' "$*")" <<'RSCRIPT'
proj=$(echo "$HOME" | sed 's:/:-:g')
d="$HOME/.claude/projects/$proj"
q="$1"
any=0
for f in "$d"/*.jsonl; do
  [ -e "$f" ] || continue
  c=$(grep -ic -- "$q" "$f" 2>/dev/null || true)
  [ "${c:-0}" -gt 0 ] || continue
  id=$(basename "$f" .jsonl)
  when=$(stat -f '%Sm' -t '%b %d %H:%M' "$f" 2>/dev/null)
  printf "  %.8s  %-12s  %s matches\n" "$id" "$when" "$c"
  any=1
done
[ "$any" -eq 1 ] || echo "  no matches for: $q"
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
      s="$(list_sessions)"
      n="$(printf '%s\n' "$s" | grep -c . || true)"
      if [ "$n" -eq 0 ]; then echo "No live ic sessions."; exit 0; fi
      if [ "$n" -gt 1 ]; then
        echo "Multiple sessions - 'ic kill <id>' or 'ic kill all':"; echo "$s"; exit 1
      fi
      sess="$s"
    else
      sess="$(norm "$id")"
    fi
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
