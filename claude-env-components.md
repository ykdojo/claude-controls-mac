# Claude Code environment components

The full list of what [`setup-claude-env.sh`](setup-claude-env.sh) can install.
Core items (1-9) are on by default; opt-ins (10-11) are off by default. In
interactive mode you can toggle any combination.

## Core (on by default)

1. **Shell aliases** - `c` = `claude`, `cs` = `claude --dangerously-skip-permissions`,
   and a `claude()` wrapper that expands `--fs` to `--fork-session`. Added to
   `~/.zshrc`.
2. **DX plugin** - the `dx` plugin from
   [ykdojo/claude-code-tips](https://github.com/ykdojo/claude-code-tips). Installs
   the Xcode Command Line Tools first if missing, since the plugin marketplace
   needs git.
3. **Disable auto-updater + prompt suggestions** - `settings.json`:
   `DISABLE_AUTOUPDATER=1` and `promptSuggestionEnabled: false` (suppresses the
   speculative next-prompt prefill in the input box).
4. **Default model** - `settings.json`: pins `claude-opus-4-8`.
5. **Attribution off** - `settings.json`: empties the
   [commit/PR attribution](https://github.com/ykdojo/claude-code-tips#disable-commitpr-attribution)
   and sets `sessionUrl: false`, so Claude Code doesn't add itself to commits or PRs.
6. **context-bar [status line](https://github.com/ykdojo/claude-code-tips#tip-0-customize-your-status-line)** -
   downloads [`context-bar.sh`](https://github.com/ykdojo/claude-code-tips/blob/main/scripts/context-bar.sh)
   and wires it into `settings.json`.
7. **Disable auto-compact** - `.claude.json`: `autoCompactEnabled: false`.
8. **GitHub CLI (gh)** - installs the `gh` binary into `~/.local/bin` (and the
   Command Line Tools for git). Authenticate separately with `gh auth login`.
9. **Claude in Chrome guidance** - appends a marker-delimited "Claude for
   Chrome" section to `~/.claude/CLAUDE.md` so browser use is efficient: get
   element refs from the accessibility tree (`read_page`), locate elements by
   description (`find`), interact via `ref` instead of coordinates, and never
   take screenshots unless explicitly asked. Existing CLAUDE.md content is
   preserved; re-runs replace the block instead of duplicating it. Harmless
   without the extension; it only kicks in when the browser tools are present
   (see [step 14](README.md#14-set-up-claude-in-chrome-optional)).

## Opt-in (off by default)

10. **Playwright MCP** - browser automation. Installs Node (if missing) and
    Google Chrome, then registers the MCP as `playwright-mcp --browser chrome`
    (headed). Enable with `--playwright`.
11. **yt-dlp** - the `yt-dlp` binary plus a skill, for downloading video/audio
    from YouTube and other sites. Enable with `--yt-dlp`.
