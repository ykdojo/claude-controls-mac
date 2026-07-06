# How to set up your spare Mac for Claude Code to fully control - a step-by-step guide

Here's a full step-by-step guide on how to turn your spare Mac into an always-on
machine Claude Code can fully control, with computer use enabled. You'll be able to talk to it from your phone
through the Claude app, or from your main Mac over SSH.

## Why do this?

I wanted to create a separate environment Claude Code can control on its own, so I can
delegate tasks I don't necessarily want to run on my own machine - certain types of
research tasks, and development tasks.

Claude Code, especially with the `--dangerously-skip-permissions` flag on, always
carries some risk when run on your main machine. You can eliminate / mitigate these
risks by creating a separate environment on your spare Mac with everything it needs
to have access to.

It has an added bonus of being able to talk to Claude Code anytime, anywhere from
your phone. I've personally found it really useful because I often prefer to talk to
Claude Code instead of regular Claude on the mobile app - Claude Code is often more
capable.

The following guide assumes you have your main Mac as well as a spare Mac you can set
up for this, but you should be able to take inspiration from it and apply it to any
combination of two machines.

## Why this setup?

First, let's quickly address a few questions you might have.

### Why not run it in a container?

I'm a big proponent of running it in a container - I even built
[an entire environment for doing so conveniently](https://github.com/ykdojo/safeclaw).
However, I've found it has a few limitations.
First, it still runs on your main machine, so it's not completely separated. For
example, network requests it sends still go through your main machine.

Second, there are limitations to the container's capabilities. For example, I wanted
my agent to be able to run Unity for game development, and there's no easy way to do
that in a container. The same goes for any other app that's only available on a Mac -
you won't have access to it. That's especially relevant if you want Claude Code to
control these apps through computer use - clicking, dragging, and so on.

### Why not use something like OpenClaw?

I personally like having access to the full, latest features of Claude Code. I also
like being able to control it from the Claude app - I've found it really convenient.
And you get to use your Claude subscription usage if you happen to have one, which is
an added bonus.

At the end of the day, running an agent with broad permissions is safer on a machine
that has nothing to lose - but you get the benefit of being able to use a full Mac
instead of a container. The approach here:

- **Use an old/spare Mac**, not your main one.
- **Create a fresh local account with no personal data and no Apple ID** signed in, so
  the agent has nothing sensitive to reach.
- **Drive it over SSH** from your main Mac on your local network, and control it from
  your phone.

## What you'll need

- A spare Mac (the **target**).
- Your everyday Mac (the **source**), on the same Wi-Fi.

---

## 1. Start fresh on the target Mac

### Wipe it first (if it has any personal data)

You'll be giving the agent full access to this machine, so it can reach anything stored
on it. If there's existing data you don't want it to have access to, erase the machine
first:

- **Macs that support it:** System Settings -> General -> Transfer or Reset ->
  **Erase All Content and Settings**.
- **Older Intel Macs:** restart into Recovery (hold **Cmd-R** at
  boot), use **Disk Utility** to erase the internal drive, then reinstall macOS.

Optionally update to the latest macOS afterward (System Settings -> General ->
Software Update).

### Create a fresh, isolated account

- Create a **new local user account** (System Settings -> Users & Groups).
- **I recommend not signing into an Apple ID.** Skip it during setup.

### Make the account an admin (if you haven't already)

The account needs admin rights or `sudo` will refuse to run.

- System Settings -> Users & Groups -> set the account to **Allow this user to
  administer this computer**.
- If you ever need to repair it from another admin account:
  `sudo dseditgroup -o edit -a <user> -t user admin`

---

## 2. Enable Remote Login (SSH) on the target Mac

On the **target**, turn on SSH so the source Mac can connect:

```bash
sudo systemsetup -setremotelogin on
```

If the command fails with `Turning Remote Login on or off requires Full Disk Access
privileges`, give your terminal app Full Disk Access first:

- System Settings -> Privacy & Security -> **Full Disk Access**.
- Click **+**, then in the file picker go to **Applications -> Utilities -> Terminal**
  and add it.
- Quit and reopen the terminal, then rerun the command.

---

## 3. Passwordless sudo for the target account

This is so the agent (and your SSH commands) can run admin tasks without a password
prompt each time. Run this once on the target. It
asks for the login password this one time:

```bash
echo "<user> ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/<user>-nopasswd >/dev/null
sudo chmod 440 /etc/sudoers.d/<user>-nopasswd
sudo visudo -cf /etc/sudoers.d/<user>-nopasswd   # validate - must print 'parsed OK'
```

This creates a small rule file telling the Mac that `<user>` can run `sudo` without a
password prompt:

- **line 1** writes the rule into `/etc/sudoers.d/`.
- **line 2** makes it read-only - sudo ignores the file otherwise.
- **line 3** validates the syntax; a typo in a sudoers file can lock you out of `sudo`
  entirely, so it must print `parsed OK`.

After this, `sudo` runs with no prompt - test with `sudo -n true`, which succeeds
silently if passwordless sudo works.

---

## 4. Find the target's address (hostname or IP)

You can reach the target by either a hostname or an IP. I recommend using the
hostname: it stays the same, while the IP can change.

**Hostname (recommended).** Run on the target:

```bash
scutil --get LocalHostName      # prints the hostname, e.g. MacBook-Pro
```

Add `.local` to form the address: `<target-host>.local`. You can also read it from
System Settings -> General -> Sharing, shown as `Local hostname`.

> **Give the target a unique name.** Each Mac needs a `.local` name that's unique on
> your network. If two machines share a name, the address can point to the wrong Mac.
> Make sure the target's name is unique - rename it if needed:
>
> ```bash
> sudo scutil --set LocalHostName newmacbook   # -> newmacbook.local
> ```

**IP address (not recommended).** Run on the target:

```bash
ipconfig getifaddr en0          # e.g. 192.168.1.80
```

Note that the IP can change after a reboot or after a certain amount of time.

Throughout the rest of this guide, replace `<user>` with the target account name and
`<target-host>` with the hostname from above, so the address is
`<user>@<target-host>.local`. You could also instead use an IP in place of
`<target-host>.local`.

---

## 5. Set up passwordless SSH from the source Mac

On the source Mac, create an SSH key (skip if you already have one):

```bash
ssh-keygen -t ed25519
```

Install your public key on the target. This asks for the target account's login
password once:

```bash
ssh-copy-id <user>@<target-host>.local
```

Test it - this should print the target username with no password prompt:

```bash
ssh <user>@<target-host>.local whoami
```

---

## 6. Keep the target awake

By default macOS sleeps after ~10 minutes idle, even when plugged in, which takes
it off the network. To make it never sleep, run this on the target (or over SSH from
the source):

```bash
sudo pmset -c sleep 0          # never system-sleep while plugged in (-c = on charger)
sudo pmset -c disablesleep 1   # also prevents sleep with the lid closed (clamshell)
sudo pmset -c displaysleep 0   # keep the display on too
```

Verify:

```bash
pmset -g | grep -iE 'sleep'
```

`sleep 0`, `SleepDisabled 1`, and `displaysleep 0` in the output confirm it worked.

If the machine runs on battery sometimes, use `-a` instead of `-c` to apply to all
power sources (at the cost of battery drain).

The screen can still lock when the screen saver kicks in. Stop the screen saver
from ever starting so it never locks on its own:

```bash
defaults -currentHost write com.apple.screensaver idleTime 0
```

---

## 7. Clipboard sync over SSH

macOS ships `pbcopy` (write clipboard) and `pbpaste` (read clipboard). Piped over SSH,
they can move the clipboard between machines - encrypted, peer-to-peer, no Apple ID or
third-party service.

[`clip.sh`](clip.sh) wraps this into one command with two subcommands, and adds image
support on top of `pbcopy`/`pbpaste` (which are text-only). Install it as a script on your PATH
on the source Mac, and point it at the target host with `IC_BOX` ("ic" standing for
"isolated claude"):

```bash
curl -fsSL https://raw.githubusercontent.com/ykdojo/claude-controls-mac/main/clip.sh -o ~/.local/bin/clip
chmod +x ~/.local/bin/clip
export IC_BOX="<user>@<target-host>.local"   # add to ~/.zshrc
```

Usage:

- **`clip send`** - this Mac's clipboard → the target (text or image). For an image you can
  paste it straight into a Claude Code session on the target with **Ctrl-V** (the target has
  one shared pasteboard for SSH and GUI sessions, and Claude reads it on paste; the terminal
  can't carry image bytes through a normal paste).
- **`clip get`** - the target's clipboard → this Mac (text or image); then Cmd-V to paste.

---

## 8. Install Claude Code on the target Mac

Send the install command over and run it. From the source Mac you can push it straight
to the target's clipboard, or run it remotely. The version is pinned for a reproducible
install (matches [safeclaw](https://github.com/ykdojo/safeclaw); bump it as you like - the
auto-updater is off, so the box stays on whatever you install):

```bash
ssh <user>@<target-host>.local 'curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.201'
```

The native installer may warn that `~/.local/bin` is not on PATH. Fix it on the target by
adding it to `~/.zshenv` (not `~/.zshrc`) - `.zshenv` is read by *every* zsh, including
non-interactive ones, so `claude` is also found by `zsh -c ...` (which step 11 relies on):

```bash
ssh <user>@<target-host>.local 'echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshenv'
```

---

## 9. Set up an opinionated Claude Code environment (optional)

The box works now. This optional step applies a set of opinionated defaults via
[`setup-claude-env.sh`](setup-claude-env.sh) in this repo - shell aliases, the DX
plugin, `settings.json` tweaks, the GitHub CLI, and (opt-in) Playwright MCP and
yt-dlp. Every item is toggleable; see the full list in
[`claude-env-components.md`](claude-env-components.md).

**Interactively on the target** - shows a checklist of every item (core
pre-checked, opt-ins unchecked) so you can pick any combination. Download the
script onto the target and run it:

```bash
ssh -t <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/ykdojo/claude-controls-mac/main/setup-claude-env.sh -o setup-claude-env.sh && bash setup-claude-env.sh'
```

**Non-interactively** - no prompt; core only, or add flags (`--yt-dlp`,
`--playwright`, `--all`, `--core`):

```bash
ssh <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/ykdojo/claude-controls-mac/main/setup-claude-env.sh -o setup-claude-env.sh && bash setup-claude-env.sh --all'
```

The script is idempotent (OK to re-run).

---

## 10. Log in to Claude and GitHub

Both logins are interactive, so SSH in:

```bash
ssh <user>@<target-host>.local
```

Then run `claude` on the target - it drops into the login for your Anthropic (Claude)
account. Follow the prompts (a browser/device-code flow you can finish from a browser
on your main Mac).

**GitHub - optional, but highly recommended** so the agent can work with repos:

```bash
gh auth login
```

I personally recommend using a separate GitHub account, not your main one, so it
doesn't mess up your main account.

---

## 11. Computer use over SSH (optional)

Lets an interactive `claude` session on the target see (screenshots) and control
(mouse/keyboard) its own desktop, driven over SSH.

This doesn't work out of the box - SSH and macOS's permission model get in the way, so the
setup below exists to route around that.

**Why it needs a workaround:** macOS gates screen capture and input behind Screen Recording
and Accessibility permissions that are GUI-only and tied to the GUI login session, so an SSH
process can't reach the display. Fix: a LaunchAgent keeps a `tmux` server alive *inside* the
GUI session on a fixed socket; every `claude` session created there (by `ic`) lands on that
server and inherits the GUI session, so it can reach the display. You attach over SSH.

(tmux, not screen: macOS's system `screen` is the 2006 4.00.03 build, which can't render
emoji, and even Homebrew screen 5.x replaces astral-plane emoji like 📁 with a placeholder.
tmux renders them correctly, and its single-server model is simpler to drive.)

### Scriptable setup

Run [`setup-computer-use.sh`](setup-computer-use.sh) on the target:

```bash
ssh -t <user>@<target-host>.local \
  'curl -fsSL https://raw.githubusercontent.com/ykdojo/claude-controls-mac/main/setup-computer-use.sh -o setup-computer-use.sh && bash setup-computer-use.sh'
```

Installs the LaunchAgent (persistent `tmux` server with anchor session `cc`) and enables the
built-in `computer-use` tool in `~/.claude.json`. Requires tmux (`brew install tmux`) and a
Claude Pro or Max plan. Re-runnable; `--uninstall` to remove.

### Use it from your Mac

Install [`ic.sh`](ic.sh) (`ic` = "isolated claude") on the source Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/ykdojo/claude-controls-mac/main/ic.sh -o ~/.local/bin/ic
chmod +x ~/.local/bin/ic
echo 'export IC_BOX="<user>@<target-host>.local"' >> ~/.zshrc   # or edit the default in the script
```

Each `ic` spawns its own `claude` session on the box (run several at once) and attaches.
Flags mirror `claude`:

```bash
ic               # new claude session
ic -c            # continue the most recent conversation (forwards to: claude -c)
ic -r            # resume picker (forwards to: claude -r)
ic sh            # a plain shell on the box, no claude (alias: ic shell)
ic rc            # Remote Control: drive the box from your phone (claude remote-control)
ic history       # stored conversations: count, location, recent w/ previews (alias: hist)
ic ls            # list live sessions (state, age, what's running, conversation)
ic attach <id>   # attach a running session (alias: ic a)
ic kill <id>     # kill a session (alias: ic k); "ic kill all" kills all
ic -h            # help
```

All `ic` sessions run with `--dangerously-skip-permissions` (and `ic rc` uses
`--permission-mode bypassPermissions`) - the box is an isolated sandbox, so prompts are auto-approved.

**Copying text out:** sessions run in tmux, and Terminal.app can't receive the clipboard escape
sequences (OSC52) that claude emits, so mouse-selecting a snippet won't reliably reach your Mac
clipboard. Quick workaround: **Cmd-A then Cmd-C** copies the whole visible screen.

### Bonus: let your Mac's Claude drive the box's Claude

Because every `ic` session lives on the box's tmux server at a fixed socket, a Claude Code
session on your source Mac can prompt one directly over SSH - useful for delegating work
to the box and checking on it, agent to agent:

```bash
# find the session (ic ls prints the ids)
ic ls

# type a prompt into it, then confirm with a second Enter - with longer prompts,
# an Enter sent in the same burst as the text doesn't register as submit and the
# prompt sits in the input box (short prompts usually submit fine)
ssh <user>@<target-host>.local "tmux -S /tmp/cc-tmux.sock send-keys -t <session> 'Switch to main and pull; PR #4 is merged.' Enter"
sleep 2
ssh <user>@<target-host>.local "tmux -S /tmp/cc-tmux.sock send-keys -t <session> Enter"

# read the reply (re-run / poll until the spinner is gone)
ssh <user>@<target-host>.local "tmux -S /tmp/cc-tmux.sock capture-pane -t <session> -p" | tail -30
```

Keep prompts single-quote-free (or escape them) since they pass through `send-keys`, and
check the captured pane before sending - if a human is mid-typing in that session, you'd be
appending to their prompt.

### One-time grants (can't be scripted)

Screen Recording and Accessibility can only be granted in the GUI, and a human has to do it at
the machine (in person or via Screen Sharing) - macOS blocks synthetic clicks on these prompts.
On first capture you'll also **Allow** a *"bypass the window picker"* prompt (recurs ~monthly).

**The grants go on `tmux`, not `claude`.** macOS attributes
capture/control to the *responsible process* in the chain, which here is the `tmux` server
(claude runs as its child, reparented to launchd). So:

1. Grant `tmux` (`/usr/local/bin/tmux`, or `/opt/homebrew/bin/tmux` on Apple Silicon) under
   both Screen Recording and Accessibility - Screen Recording covers screenshots,
   Accessibility covers mouse/keyboard control. Granting only one leaves the other failing.
2. **Restart the tmux server after granting** - a running process caches its permission state
   at launch, so a grant won't take effect until the server restarts:
   `tmux -S /tmp/cc-tmux.sock kill-server` (the LaunchAgent respawns the anchor within seconds).
   claude sessions started after the restart pick up the new grant.

To make the entries appear in System Settings in the first place, trigger a computer-use action
(`ic`, then ask Claude to "take a screenshot") - macOS adds `tmux` to the list (toggled off) so
you can switch it on. Switching from a previous `screen`-based setup surfaces these prompts
again because the responsible process changed.

The `claude` binary does not need its own grant (verified: with `claude` toggled off and
only `tmux` on, computer use still works). A bonus over the old screen setup: because the grant
is tied to `tmux`, a `claude` auto-update - which moves its versioned binary path - no longer
drops computer-use access. Only a `tmux` upgrade would, which is rare.

---

## 12. Install a VPN (optional)

I like to run a VPN on the box so its traffic goes out separately from my local IP. I
personally use Proton VPN - it has a free tier and I've been using them for a long
time - but there are plenty of options.

You can just ask the box's Claude to do it: `ic` in and say "install Proton VPN". It'll
download and install the app. The parts it can't do alone:

- **Credentials.** Signing in is required (even free tiers need an account), and that's
  yours to enter. Send the password over securely with `clip send` from
  [section 7](#7-clipboard-sync-over-ssh): copy it on your Mac, run `clip send`, then paste
  into the sign-in field on the box.
- **macOS permission prompts.** The first connect pops a system prompt to allow a VPN /
  network configuration (and may ask for the Mac password) - approve it at the machine.
- **Computer use for the GUI.** The app is GUI-only, so driving it relies on
  [section 11](#11-computer-use-over-ssh-optional) being set up. Once signed in, the agent
  can connect and switch servers itself.
