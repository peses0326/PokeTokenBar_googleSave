# ptb — PokeTokenBar_gs on Linux servers and other computers

The menu-bar app is macOS only. `ptb` covers every other computer you code on:

- **Usage counts toward growth.** `ptb push` reads that computer's Claude Code and Codex logs and uploads daily token totals to `PokeTokenBar_Save` in your Google Drive. On its next sync (at most every 30 minutes), the Mac app grows the companion by the new usage.
- **See your progress.** `ptb status` and `ptb dex` show the companion and the Pokédex from the latest save in Drive.

The Mac stays the only place that changes the save. Its menu bar and popover keep showing that Mac's own usage. Settings → Google sync lists the other devices' usage for today.

## Requirements

- Python 3.9+ (standard library only) and `cron`
- The same Google account as the Mac app
- SSH access from the Mac to the server (only for the one-time sign-in)

## Install

On the Mac, package `ptb` with the same OAuth client JSON used for the app build, then copy it to the server:

```sh
python3 scripts/build-ptb.py --oauth-client-config ~/.config/poketokenbar-gs/oauth-client.json
scp -r build/ptb <server>:~/.local/share/poketokenbar-gs
```

On the server:

```sh
python3 ~/.local/share/poketokenbar-gs/ptb.py install    # adds ~/.local/bin/ptb and a cron job (every 30 min)
```

Options for `install`:

| Option | Default | Use |
|---|---|---|
| `--timezone` | `Asia/Seoul` | Day boundary for usage. Use the Mac's timezone. |
| `--name` | hostname | Name shown in the Mac app and in the Drive file name |
| `--interval` | `30` | Minutes between pushes (5, 10, 15, 20 or 30) |
| `--claude-root` / `--codex-root` | `~/.claude/projects`, `~/.codex/sessions` | Other log folders, repeatable |

## Sign in (once)

The server has no browser, so the Google consent page opens on the Mac through an SSH tunnel:

```sh
# Mac, terminal 1: keep this open
ssh -L 8765:127.0.0.1:8765 <server>

# In that SSH session (or another one on the server)
ptb login
# Open the printed URL in the Mac's browser and approve with the same Google account.
```

Then check it:

```sh
ptb push      # one line: "pushed N days, today X tokens"
ptb status
ptb dex
```

## How usage is counted

- Same rule as the Mac app: input + output + cache write + cache read tokens. Codex forks and subagents are not counted twice.
- The first run reads the existing logs once. After that, only new lines are read. Read offsets and token counts are kept in `collector/usage.sqlite3`; prompts and code are never stored or uploaded.
- Each computer keeps **one** usage file in Drive (`PokeTokenBar-Usage-<name>.json`), rewritten in place, with the last 14 days.
- The Mac credits only usage **after** it first sees a device, so history from before setup is not paid out at once. A late upload for yesterday (just after midnight) still counts. Which usage was credited is stored in the save, so a second Mac does not credit it again.
- Don't run `ptb push` on a Mac that runs the app (it refuses): that Mac's usage would count twice.

## Uninstall

```sh
ptb uninstall                                  # removes the cron job
rm -rf ~/.local/share/poketokenbar-gs ~/.local/bin/ptb
```

Then delete `PokeTokenBar-Usage-<name>.json` from the Drive folder if you like. The save is not affected.
