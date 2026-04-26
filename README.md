# tmux-resurrect-launchd

A macOS [launchd](https://www.launchd.info/) job that periodically saves your tmux state via [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), so you can recover sessions after a crash even when [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum)'s built-in autosave isn't firing.

## Why this exists

`tmux-continuum` triggers periodic saves by embedding a shell call (`#(continuum_save.sh)`) in tmux's `status-right`. tmux re-renders `status-right` on every `status-interval` tick, which is what gives continuum its heartbeat.

That mechanism doesn't fire reliably under iTerm2's [`tmux -CC` control mode](https://iterm2.com/documentation-tmux-integration.html). In control mode, iTerm renders the chrome itself and tmux's status bar isn't drawn the usual way, so the embedded shell call never runs. Continuum effectively saves once at session start and then goes silent.

This daemon sidesteps the whole status-bar mechanism: it runs `tmux-resurrect`'s save script on a fixed `launchd` schedule, regardless of how (or whether) anything is attached.

Related upstream issues:
- [tmux-continuum #40 — Does continuum work with iTerm2 -CC?](https://github.com/tmux-plugins/tmux-continuum/issues/40)
- [tmux-continuum #42 — Autosave doesn't work, `#{continuum_status}` is empty](https://github.com/tmux-plugins/tmux-continuum/issues/42)
- [tmux-resurrect #68 — Can this be cron'ed?](https://github.com/tmux-plugins/tmux-resurrect/issues/68)

## Requirements

- macOS
- [tmux](https://github.com/tmux/tmux) on `PATH` (Homebrew default: `/opt/homebrew/bin/tmux`)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) installed at `~/.tmux/plugins/tmux-resurrect/`

You do **not** need to keep `tmux-continuum` — this replaces its autosave. Restore on tmux start (`prefix + Ctrl-r`) is still handled by `tmux-resurrect` directly.

## Install

```bash
git clone https://github.com/<you>/tmux-resurrect-launchd.git
cd tmux-resurrect-launchd
./install.sh
```

The installer:
1. Verifies `tmux` and `tmux-resurrect` are present.
2. Renders `com.user.tmux-resurrect-save.plist` with your `$HOME` and copies it to `~/Library/LaunchAgents/`.
3. Loads the job (`launchctl load -w`).
4. Logs to `~/Library/Logs/tmux-resurrect-save.log`.

Default save interval is **15 minutes**. To change it, edit `StartInterval` in the plist (seconds), then re-run `./install.sh`.

## Verify

```bash
launchctl list | grep tmux-resurrect-save     # should show the label
ls -lt ~/.tmux/resurrect/ | head              # newest snapshot file
tail ~/Library/Logs/tmux-resurrect-save.log
```

The job runs once on load (`RunAtLoad`), so you should see a fresh snapshot within seconds of installing.

## Uninstall

```bash
./uninstall.sh
```

Removes the launchd job and the plist. Existing snapshots in `~/.tmux/resurrect/` are left alone.

## How it works

The plist invokes a one-line shell command every `StartInterval` seconds:

```sh
tmux ls >/dev/null 2>&1 && "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" quiet
```

If no tmux server is running, the save is skipped (no empty snapshots). If one is, `tmux-resurrect`'s normal save script runs in `quiet` mode.

## License

MIT
