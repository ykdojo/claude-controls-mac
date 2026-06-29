# Setting up a dedicated Mac for Claude Code (full access, isolated)

How to turn a spare Mac into a remote, full-access machine for running Claude Code,
controlled over SSH from your main Mac - with secure clipboard sync between the two.

## Why this setup

Running an agent with broad permissions is safer on a machine that has nothing to lose.
The approach here:

- **Use an old/spare Mac**, not your main one.
- **Create a fresh local account with no personal data and no Apple ID** signed in, so
  the agent has nothing sensitive to reach.
- **Drive it over SSH** from your main Mac on the local network.
- **Move text between the two with a clipboard-over-SSH shortcut.**

The result is an isolated sandbox you can give full access to, while still being able
to control it from your main machine.

## What you need

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
- **Older Intel Macs (or to repartition):** restart into Recovery (hold **Cmd-R** at
  boot), use **Disk Utility** to erase the internal drive, then reinstall macOS.

Optionally update to the latest macOS afterward (System Settings -> General ->
Software Update).

### Create a fresh, isolated account

- Create a **new local user account** (System Settings -> Users & Groups).
- **Do not sign into an Apple ID.** Skip it during setup.
- Keep it empty: no personal files, no synced accounts.

### Make the account an admin (if you haven't already)

The account needs admin rights or `sudo` will refuse to run (`<user> is not in the
sudoers file. This incident has been reported to the administrator.`).

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

So the agent (and your SSH commands) can run admin tasks - `pmset`, `scutil`,
installs - without a password prompt each time. Run this **once on the target** (it
asks for the login password this one time):

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

After this, `sudo` runs with no prompt (test with `sudo -n true`).

---

## 4. Find the target's address (hostname or IP)

You can reach the target by either a hostname or an IP. Use the **hostname**: it stays
the same, while the IP can change.

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

The IP comes from DHCP and can change after a reboot or when the lease expires.

> Throughout the rest of this guide, replace `<user>` with the target account name and
> `<target-host>` with the hostname from above (so the address is
> `<user>@<target-host>.local`). You can use an IP in place of `<target-host>.local`.

---

## 5. Set up passwordless SSH from the source Mac

On the **source** Mac, create an SSH key (skip if you already have one):

```bash
ssh-keygen -t ed25519
```

Install your public key on the target. This asks for the target account's **login
password** once - not your Apple ID, not the source Mac's password:

```bash
ssh-copy-id <user>@<target-host>.local
```

Test it - this should print the target username with no password prompt:

```bash
ssh <user>@<target-host>.local whoami
```

---

## 6. Keep the target awake

By default macOS sleeps after ~10 minutes idle, **even when plugged in**, which takes
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

The screen can still **lock** when the screen saver kicks in. Stop the screen saver
from ever starting so it never locks on its own:

```bash
defaults -currentHost write com.apple.screensaver idleTime 0
```

---

## 7. Clipboard sync over SSH

macOS ships `pbcopy` (write clipboard) and `pbpaste` (read clipboard). Piped over SSH,
they move the clipboard between machines - encrypted, peer-to-peer, no account, no
third-party service.

We'll set up two aliases: `sendclip` pushes your clipboard from the source to the
target, and `getclip` pulls the target's clipboard back to the source. Add them to
`~/.zshrc` on the **source** Mac:

```bash
# --- Target Mac clipboard over SSH ---
NEWMAC="<user>@<target-host>.local"
alias sendclip='pbpaste | ssh "$NEWMAC" pbcopy'
alias getclip='ssh "$NEWMAC" pbpaste | pbcopy'
```

Then run `source ~/.zshrc` to load them.

The commands take **no arguments** - they act on your system clipboard:

- **sendclip**: copy on the source (Cmd-C), run `sendclip`, paste on the target (Cmd-V).
- **getclip**: copy on the target (Cmd-C), run `getclip`, paste on the source (Cmd-V).

---

## 8. Install Claude Code on the target Mac

Send the install command over and run it. From the source Mac you can push it straight
to the target's clipboard, or run it remotely:

```bash
ssh <user>@<target-host>.local 'curl -fsSL https://claude.ai/install.sh | bash'
```

The native installer may warn that `~/.local/bin` is not on PATH. Fix it on the target:

```bash
ssh <user>@<target-host>.local 'echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc'
```

---

## 9. Set up an opinionated Claude Code environment (optional)

The box works now. This optional step applies a set of opinionated defaults via
[`setup-claude-env.sh`](setup-claude-env.sh) in this repo - shell aliases, the DX
plugin, `settings.json` tweaks, the GitHub CLI, and (opt-in) Playwright MCP and
yt-dlp. Every item is toggleable; see the full list in
[`claude-env-components.md`](claude-env-components.md).

**Interactively on the target** - shows a checklist of every item (core
pre-checked, opt-ins unchecked) so you can pick any combination:

```bash
scp setup-claude-env.sh <user>@<target-host>.local:
ssh -t <user>@<target-host>.local './setup-claude-env.sh'
```

**Non-interactively from the source** - no prompt; core only, or add flags
(`--yt-dlp`, `--playwright`, `--all`, `--core`):

```bash
ssh <user>@<target-host>.local 'bash -s -- --all' < setup-claude-env.sh
```

The script is idempotent (OK to re-run).

---

## 10. Log in to Claude and GitHub

Both logins are interactive, so SSH in with a real terminal (not a one-shot command):

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

Use a **separate GitHub account**, not your main one. This box is a full-access
sandbox, so a dedicated account keeps the agent from being able to touch your real
account's repos and settings.
