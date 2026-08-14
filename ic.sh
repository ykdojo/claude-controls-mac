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
#   ic -C '~/repo' ... # start the session in that path on the box (alias: --cd)
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
  ic -C '~/repo'     start in that path on the box (alias: --cd). Must be the
                       FIRST argument, and quote the ~. New sessions only:
                       ic, ic sh, ic rc
  ic sh              a plain shell on the box (no claude; alias: ic shell)
  ic vnc             open Screen Sharing (VNC) to the box
  ic rc              Remote Control: drive the box from your phone
                       (runs claude remote-control; extra args forward to it;
                        alias: ic remote-control)
  ic history         stored conversations in every project dir: count,
                       location, recent (alias: hist)
  ic ls              list live sessions (state, age, proc, conversation)
  ic attach <id>     attach a running session (alias: ic a)
  ic kill <id>       kill a session (alias: ic k)
  ic kill-all        kill all sessions
  ic kill-except <id> <id> ...   kill all sessions except the listed ones (space-separated)
  ic -h | --help     this help

Config: set IC_BOX to <user>@<host> (default: yk2@newmacbook.local).
Detach from a session with Ctrl-] then D; reattach with: ic attach <id>
EOF
}

# Normalize a session id: accept "ic-1234", "1234", and map to full name.
norm() { case "$1" in ic-*) printf '%s' "$1";; *) printf 'ic-%s' "$1";; esac; }

# Single-quote a string for the box's shell, so nothing in a path ($, backticks,
# spaces, quotes) is expanded or run there:  it's  ->  'it'\''s'
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Create a GUI-session tmux session on the box and attach in one step. $1 is the
# session name, $2 the command *as the box's shell should see it* (so a multi-word
# command arrives pre-quoted). Every session goes through here, so the socket, the
# -C working dir and the attach behaviour are decided in one place.
new_session() { exec ssh "$BOX" -t "tmux -S $SOCK new-session -s $1 $cdopt $2"; }

# -C <path>: the working directory for a new session (ic, ic sh, ic rc), passed
# to tmux new-session -c. Consumed here, so the remaining args dispatch below as
# usual. Home-relative paths must stay relative, because the box has its own home
# dir: that covers both a quoted ~ (which reaches this script intact) and an
# unquoted one (which your local shell already turned into *this* Mac's $HOME).
# Anything else is passed through as-is, so relative paths resolve against the
# box's home dir - the login dir of the ssh session.
cdopt=""
case "${1:-}" in
  -C|--cd)
    dir="${2:-}"
    [ -z "$dir" ] && { echo "ic: $1 needs a path (e.g. ic -C '~/repo')" >&2; exit 1; }
    rest=""; home_rel=no; expanded=no
    # shellcheck disable=SC2088  # the ~ patterns match a literal tilde on purpose
    case "$dir" in
      "~")         home_rel=yes;;
      "~/"*)       home_rel=yes; rest="/${dir#\~/}";;
      "$HOME")     home_rel=yes; expanded=yes;;
      "$HOME"/*)   home_rel=yes; expanded=yes; rest="/${dir#"$HOME"/}";;
    esac
    if [ "$home_rel" = yes ]; then
      [ "$expanded" = yes ] && echo "ic: -C $dir is under this Mac's home; using ~$rest on the box" >&2
      cdopt="-c \"\$HOME\"${rest:+$(sq "$rest")}"
    else
      cdopt="-c $(sq "$dir")"
    fi
    shift 2
    # Only the branches that create a session can honour it; the subcommands
    # below would silently drop it, so say no instead of pretending. Anything
    # else is a claude flag (open-ended) and lands on a new session.
    case "${1:-}" in
      -h|--help|help|ls|attach|a|vnc|history|hist|kill|k|kill-all|kill-except)
        echo "ic: -C does not apply to 'ic $1' - only to a new session (ic, ic sh, ic rc)" >&2; exit 1;;
    esac
    ;;
esac

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
projects="$HOME/.claude/projects"; sdir="$HOME/.claude/sessions"
sessions=$(tmux -S "$SOCK" list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null | grep '^ic-' | sort -t'|' -k3,3nr)
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
    # ic -C moves a session off the $HOME project dir, and a dir name is the cwd
    # with every non-alphanumeric mangled to - (over 200 chars: truncated with a
    # hash), so it can't be rebuilt from the cwd - find the transcript by id.
    jf=$(ls "$projects"/*/"$sid.jsonl" 2>/dev/null | head -1)
    [ -f "$jf" ] && conv=$(jq -rs '(last(.[]|select(.type=="ai-title")|.aiTitle)) // (last(.[]|select(.type=="last-prompt")|.lastPrompt)) // ""' "$jf" 2>/dev/null | tr "\n\t" "  " | sed "s/  */ /g" | cut -c1-50)
  elif [ "$proc" = claude-rc ]; then conv="(remote-control host)"; fi
  printf "%-20s %-9s %-7s %-10s %s\n" "$name" "$state" "$age" "$proc" "$conv"
done
echo ""
echo "attach: ic attach <id>   (alias: ic a; detach: Ctrl-] then D)"
echo "kill:   ic kill <id>     (alias: ic k)"
echo "        ic kill-all      / ic kill-except <id> <id> ...   (keeps only the listed ones)"
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
    new_session "$sess" zsh
    ;;

  vnc)
    # Screen Sharing accepts vnc://user@host, so BOX works as-is (the username
    # is prefilled). Requires Screen Sharing enabled on the box (README step 15).
    open "vnc://$BOX"
    ;;

  rc|remote-control)
    # Remote Control: drive the box's claude from your phone (claude.ai/code or
    # the mobile app). Runs in a GUI-session tmux session so it can read the login
    # token (the Keychain is only reachable inside the GUI session). Extra args
    # forward to `claude remote-control` (e.g. --spawn=worktree --capacity=N).
    shift
    sess="ic-rc-$(date +%H%M%S)-$$"
    # bypassPermissions: phone-spawned sessions auto-approve too (isolated box).
    new_session "$sess" "\"claude remote-control --permission-mode bypassPermissions $*\""
    ;;

  history|hist)
    # Overview of stored conversations across every project dir on the box: a
    # plain ic session runs in $HOME, but ic -C <path> gives that path its own
    # project dir, so listing only the $HOME one would hide those conversations.
    ssh "$BOX" 'bash -s' <<'RSCRIPT'
projects="$HOME/.claude/projects"
files=$(ls -t "$projects"/*/*.jsonl 2>/dev/null)
[ -z "$files" ] && { echo "No conversations yet in $projects"; exit 0; }
W=27   # width of the project column, shared by the header rows and short()
# The dir name can't be turned back into a cwd (see the note in 'ic ls'), so read
# the real cwd from the first transcript line that carries one.
cwd_of() {
  c=$(head -40 "$1" | jq -r 'select(.cwd != null) | .cwd' 2>/dev/null | head -1)
  [ -n "$c" ] || c="$(basename "$(dirname "$1")") (?)"
  printf '%s' "$c"
}
# $HOME as ~, and keep the tail of a long path (the distinguishing end), then pad
# to $W *characters*. printf's %-Ns pads by bytes, so a path with any non-ASCII
# character would shift this column; ${#p} counts what the terminal shows.
short() {
  p=$(printf '%s' "$1" | sed "s:^$HOME:~:")
  [ ${#p} -le $((W - 1)) ] || p="..$(printf '%s' "$p" | rev | cut -c1-$((W - 3)) | rev)"
  printf '%s%*s' "$p" "$(( ${#p} < W ? W - ${#p} : 0 ))" ""
}
# KB, so the header total is exactly the sum of the per-project rows below
kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
human() { awk -v k="${1:-0}" 'BEGIN{ if (k >= 1048576) printf "%.1fG", k/1048576;
                                     else if (k >= 1024) printf "%.1fM", k/1024;
                                     else printf "%dK", k }'; }
n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
# The project dirs, ordered by their newest *transcript*: resuming a conversation
# appends to its file without touching the dir's mtime, so ordering the dirs
# themselves would sink the project you are working in below stale ones. The
# header total and the rows below both come from this list, so they agree.
dirs=$(printf '%s\n' "$files" | sed 's:/[^/]*$::' | awk '!seen[$0]++')
total=$(printf '%s\n' "$dirs" | while read -r d; do kb_of "$d"; done | awk '{s+=$1} END{print s+0}')
echo "Conversations (all projects)"
echo "  $projects"
echo "  $n total · $(human "$total")"
echo ""
echo "  by project (newest first):"
printf '%s\n' "$dirs" | while read -r d; do
  c=$(ls "$d"/*.jsonl | wc -l | tr -d ' ')
  printf "    %s %4s conv  %6s\n" "$(short "$(cwd_of "$(ls -t "$d"/*.jsonl | head -1)")")" "$c" "$(human "$(kb_of "$d")")"
done
echo ""
echo "  recent:"
printf '%s\n' "$files" | head -10 | while read -r f; do
  id=$(basename "$f" .jsonl)
  when=$(stat -f '%Sm' -t '%b %d %H:%M' "$f" 2>/dev/null)
  msgs=$(wc -l < "$f" | tr -d ' ')
  prev=$(jq -rs '[.[]|select(.type=="user")][0].message.content
          | if type=="array" then (map(select(.type=="text").text)|join(" ")) else . end' \
          "$f" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-42)
  printf "  %.8s  %-12s  %4s msg  %s %s\n" "$id" "$when" "$msgs" "$(short "$(cwd_of "$f")")" "$prev"
done
echo ""
echo "  open/continue:  ic -r              (resume picker, has search)"
echo "                  ic -C <path> -r    (picker for that project)"
echo ""
echo "  to search/read, grep or jq the files directly. each is JSONL, one JSON"
echo "  object per line. key fields:"
echo "    .type            user | assistant | system | attachment | ...  (filter user/assistant for messages)"
echo "    .message.content string (user) or array of {type,text,...} blocks (assistant)"
echo "    .timestamp  .cwd  .gitBranch  .sessionId"
echo "  e.g.  ssh <box> 'grep -l TERM $projects/*/*.jsonl'"
echo "        ssh <box> \"jq -rs '[.[]|select(.type==\\\"user\\\")][].message.content' FILE\""
RSCRIPT
    ;;

  kill-all)
    ssh "$BOX" "tmux -S $SOCK list-sessions -F '#{session_name}' 2>/dev/null | grep '^ic-' | xargs -I{} tmux -S $SOCK kill-session -t {} 2>/dev/null || true"
    echo "Killed all ic sessions."
    ;;

  kill-except)
    shift
    if [ $# -eq 0 ]; then
      echo "Usage: ic kill-except <id> [<id>...]   (kills all other sessions; see 'ic ls')"; exit 1
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
    ;;

  kill|k)
    id="${2:-}"
    if [ -z "$id" ]; then
      echo "Usage: ic kill <id>   (see also: ic kill-all, ic kill-except <id> <id> ...)"; exit 1
    fi
    case "$id" in
      all|except) echo "ic: did you mean 'ic kill-$id'?" >&2; exit 1;;
    esac
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
    new_session "$sess" "\"claude --dangerously-skip-permissions $*\""
    ;;
esac
