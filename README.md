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

Always validate with `visudo -cf`: a syntax error in a sudoers file can lock you out
of `sudo` entirely. After this, `sudo -n true` succeeds with no prompt.

> **Security note.** This grants full passwordless root to anyone who can SSH in as
> `<user>`. That's an acceptable trade-off here because the account is an isolated
> sandbox with no personal data and SSH is key-only. To narrow it, replace `ALL` with
> a specific command, e.g. `NOPASSWD: /usr/bin/pmset, /usr/sbin/scutil`.

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

> **Give the target a unique name.** A spare Mac often has the same default name as
> your main Mac (e.g. both are `yks-macbook-pro.local`). Two machines on the same
> network can't share a `.local` name, so the system quietly renames one (e.g. to
> `yks-macbook-pro-2.local`) - and which Mac that points to can change, so the
> address is unreliable. Rename the target to something unique so its `.local`
> address always points to it:
>
> ```bash
> sudo scutil --set LocalHostName newmacbook   # -> newmacbook.local
> ```

**IP address.** Run on the target:

```bash
ipconfig getifaddr en0          # e.g. 192.168.1.80
```

The IP comes from DHCP and can change after a reboot or when the lease expires. If you
want a fixed IP, add a DHCP reservation in your router.

> Throughout the rest of this guide, replace `<user>` with the target account name and
> `<target-host>` with the hostname from above (so the address is
> `<user>@<target-host>.local`). You can use an IP in place of `<target-host>.local`.

---

## 5. Set up passwordless SSH from the source Mac

On the **source** Mac:

```bash
# Create a key only if you don't already have one
ssh-keygen -t ed25519

# Install your public key on the target (asks for the target account's
# LOGIN password once - not your Apple ID, not the source Mac's password)
ssh-copy-id <user>@<target-host>.local
```

Test it:

```bash
ssh <user>@<target-host>.local whoami   # should print the target username, no password
```

---

## 6. Clipboard sync over SSH

macOS ships `pbcopy` (write clipboard) and `pbpaste` (read clipboard). Piped over SSH,
they move the clipboard between machines - encrypted, peer-to-peer, no account, no
third-party service.

Add to `~/.zshrc` on the **source** Mac:

```bash
# --- Target Mac clipboard over SSH ---
NEWMAC="<user>@<target-host>.local"
alias sendclip='pbpaste | ssh "$NEWMAC" pbcopy'   # source -> target
alias getclip='ssh "$NEWMAC" pbpaste | pbcopy'    # target -> source
```

Then `source ~/.zshrc`.

Usage - the commands take **no arguments**; they act on your system clipboard:

- **sendclip**: copy on the source (Cmd-C), run `sendclip`, paste on the target (Cmd-V).
- **getclip**: copy on the target (Cmd-C), run `getclip`, paste on the source (Cmd-V).

---

## 7. Install Claude Code on the target Mac

Send the install command over and run it. From the source Mac you can push it straight
to the target's clipboard, or run it remotely:

```bash
ssh <user>@<target-host>.local 'curl -fsSL https://claude.ai/install.sh | bash'
```

The native installer may warn that `~/.local/bin` is not on PATH. Fix it on the target:

```bash
ssh <user>@<target-host>.local 'echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc'
```

Then **open a fresh terminal session on the target** (or SSH in interactively) and run
`claude` to log in - the login flow is interactive, so it needs a real terminal, not a
one-shot SSH command.

```bash
ssh <user>@<target-host>.local      # then run: claude
```

---

## 8. Keep the target awake (prevent sleep)

By default macOS sleeps after ~10 minutes idle, **even on AC power**, which takes it
off the network. For a headless remote box you want it to never sleep while plugged in.

Run on the target (or over SSH from the source):

```bash
sudo pmset -c sleep 0          # never system-sleep while on AC power (-c = on charger)
sudo pmset -c disablesleep 1   # also prevents sleep with the lid closed (clamshell)
```

Verify:

```bash
pmset -g | grep -iE 'sleep'    # 'sleep 0' and 'SleepDisabled 1' confirm it
```

The display can still sleep (`displaysleep`) - that's fine, it doesn't drop the
network. If the machine runs on battery sometimes, use `-a` instead of `-c` to apply
to all power sources (at the cost of battery drain).

---

## Remote access (different networks)

Everything above works only on the **same local network**. To reach the target from
anywhere without exposing it to the internet, add [Tailscale](https://tailscale.com) on
both Macs - it gives each a stable private IP that works from any network, still
end-to-end encrypted, no router port-forwarding.

---

## Quick reference

| Action | Command (run on source Mac) |
| --- | --- |
| Shell on target | `ssh <user>@<target-host>.local` |
| Run Claude Code on target | `ssh -t <user>@<target-host>.local 'claude'` |
| Send clipboard to target | `sendclip` |
| Pull clipboard from target | `getclip` |
| Target's Wi-Fi IP (run on target) | `ipconfig getifaddr en0` |
| Stop the target sleeping | `ssh <user>@<target-host>.local 'sudo pmset -c sleep 0 && sudo pmset -c disablesleep 1'` |
| Check it won't sleep | `ssh <user>@<target-host>.local 'pmset -g \| grep -i sleep'` |
