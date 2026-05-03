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

> **Disable continuum's autosave if you keep continuum installed.** Concurrent saves from this daemon and continuum can race over the same snapshot timestamp and pane-contents tarball. Either remove `tmux-continuum` from your tmux config, or set `set -g @continuum-save-interval '0'` in `~/.tmux.conf` to silence its timer while keeping its other behaviors (e.g. auto-restore on start).

## Install

```bash
git clone https://github.com/omriariav/tmux-resurrect-launchd.git
cd tmux-resurrect-launchd
./install.sh
```

The installer:
1. Verifies `tmux` and `tmux-resurrect` are present.
2. Drops three named scripts into `~/.local/bin/`: `tmux-resurrect-tick` (the launchd worker), `tmux-resurrect-restore` (the interactive picker, see below), and `tmux-resurrect-precheck` (the shell-rc nudge, see below).
3. Renders `com.user.tmux-resurrect-save.plist` with your `$HOME` and copies it to `~/Library/LaunchAgents/`.
4. Loads the job (`launchctl load -w`).
5. Optionally wires the precheck nudge into your shell rc (interactive prompt, or `--precheck` / `--no-precheck`).
6. Logs to `~/Library/Logs/tmux-resurrect-save.log`.

Default save interval is **15 minutes**. To change it, edit `StartInterval` in the plist (seconds), then re-run `./install.sh`.

## Recovery

After a crash or reboot, run from a fresh non-tmux shell:

```bash
tmux-resurrect-restore
```

That opens an interactive picker listing snapshots newest-first, with timestamps, age, session/pane counts, size, and session names. The macOS last-boot time is rendered as a horizontal rule so post-crash regressions are visually distinct from your pre-crash state. The recommended pick (newest pre-boot snapshot with ≥ 3 panes) is highlighted; press Enter to take it.

Non-interactive forms:

```bash
tmux-resurrect-restore --list                     # machine-readable rows; safe inside tmux
tmux-resurrect-restore --restore latest-good      # newest snapshot with >= 3 panes
tmux-resurrect-restore --restore 20260503T143047  # explicit timestamp
tmux-resurrect-restore --restore latest-good --no-confirm
```

`--list` is the only form that runs inside tmux — anything else would have to kill the server you're sitting in, so the script refuses early.

The picker handles the full sequence: drops a `~/.tmux/resurrect/.restoring` fence so the next launchd tick can't race it, stops the save daemon, kills the current tmux server (with confirmation), repoints `~/.tmux/resurrect/last`, starts a fresh detached server, runs `tmux-resurrect`'s `restore.sh` via `tmux run-shell` (necessary — without a client context, tmux's `display-message` mangles tab delimiters and the resurrect socket query returns empty), drops the bootstrap session, re-arms the daemon, and removes the fence. Reattach with iTerm2's `tmux -CC attach -t <session>`.

### If a restore aborts mid-flight

The cleanup trap is phase-aware: the daemon is **only** re-armed when the restore completes successfully. A tick after a half-finished restore would otherwise save the bootstrap-only state as the new `last` and overwrite your snapshot — so on any abort, the daemon is intentionally left unloaded, the `.restoring` fence is removed, and the script prints recovery instructions specific to the phase reached:

| Phase reached         | What you have                          | Next step                                                                 |
|-----------------------|----------------------------------------|---------------------------------------------------------------------------|
| `daemon_unloaded`     | server intact; daemon off              | `launchctl load -w ~/Library/LaunchAgents/com.user.tmux-resurrect-save.plist` |
| `server_killed`       | no server; daemon off                  | `tmux new-session -d -s recovery && tmux-resurrect-restore` (retry)       |
| `server_started`      | bootstrap session only; daemon off     | `tmux kill-server && tmux-resurrect-restore` (retry)                      |
| `restore_completed`   | sessions restored; daemon off          | inspect with `tmux ls`; if good, manually re-arm the daemon               |

## Regression guard

The tick script protects `~/.tmux/resurrect/last` against silent overwrites. After each save, it compares the new snapshot's pane count to the prior `last`. If a meaningful prior state (≥ 2 panes) was replaced by a degenerate one (≤ 1 pane), the new timestamped file is kept on disk for forensics but `last` is reverted. This is the post-Mac-reboot case: a fresh tmux server starts saving its empty default session over your real recovery point. The guard preserves the recovery point until you run `tmux-resurrect-restore`.

If you legitimately tear down sessions to one pane and want the new state to stick:

```bash
touch ~/.tmux/resurrect/.allow_regression   # one-tick bypass; sentinel auto-removed
```

## Shell-rc nudge

The optional precheck nudges you on new shells when the latest snapshot has sessions that aren't currently running. One yellow line, then nothing. Suppressed when `$TMUX` is set (you're already inside tmux), when `TMUX_RESURRECT_QUIET=1`, or for 24 hours after `touch ~/.cache/tmux-resurrect/dismissed`.

Wired with a managed block in your shell rc:

```sh
# >>> tmux-resurrect-launchd >>>
[ -x "$HOME/.local/bin/tmux-resurrect-precheck" ] && "$HOME/.local/bin/tmux-resurrect-precheck"
# <<< tmux-resurrect-launchd <<<
```

Re-run `./install.sh --precheck` to add it later, or `./uninstall.sh` to strip the block (along with everything else).

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

Removes the launchd job, the plist, and the three binaries in `~/.local/bin/`. Strips the precheck managed block (`# >>> tmux-resurrect-launchd >>>` … `# <<< tmux-resurrect-launchd <<<`) from `~/.zshrc`, `~/.bashrc`, and `~/.bash_profile` if present — refuses to touch the rc if the start marker is there but the end marker has gone missing (would otherwise delete everything below it), and writes via `cat > "$rc"` rather than `mv` so a symlinked dotfile keeps its inode.

Existing snapshots in `~/.tmux/resurrect/` and the log at `~/Library/Logs/tmux-resurrect-save.log` are left alone — `rm` them manually if you want.

## How it works

The installer drops three named scripts in `~/.local/bin/` and registers a `launchd` agent that runs `tmux-resurrect-tick` every `StartInterval` seconds. Named scripts (instead of inline `/bin/sh -c` blobs) make the processes show up by name in `ps`, Activity Monitor, and macOS Background Items notifications.

The tick script:

```sh
export PATH=<tmux-dir>:$PATH
tmux ls >/dev/null 2>&1 || exit 0
# capture pane count of current `last`
tmux run-shell "<home>/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet"
# if new pane count regressed sharply, revert the symlink
```

- `PATH` is set explicitly because `launchd` jobs run with a minimal default `PATH` that omits `/opt/homebrew/bin` and `/usr/local/bin`, and `tmux-resurrect`'s scripts call bare `tmux` internally.
- `$HOME` is substituted to a literal path at install time because `launchd` doesn't reliably propagate it to children via `/bin/sh`.
- If no tmux server is running, the save is skipped (no empty snapshots).
- `save.sh` is wrapped in `tmux run-shell` rather than executed directly. Without an attached client, tmux's `display-message` mangles tab delimiters in its format output — `save.sh` relies on those tabs and would otherwise write 12-byte snapshots containing only `state_main_` (underscores in place of tabs). `tmux run-shell` establishes a proper client context, the same one `tmux-continuum` gets implicitly from being invoked inside `status-right`. The same fix applies to the restore path: `tmux-resurrect-restore` invokes the plugin's `restore.sh` through `tmux run-shell` so `$TMUX` is populated and the resurrect socket query (`tmux_socket()` in the plugin) returns a non-empty value.
- The regression guard runs after `save.sh` returns, comparing pane counts in the prior and new `last` targets. The new file is always kept; only the symlink is potentially reverted.
- The tick yields to a manual restore via a `~/.tmux/resurrect/.restoring` fence file. While the fence exists, the tick logs `skipped (restore in progress)` and exits without saving. The fence is fail-open: a stale file older than 10 minutes (left behind by a `kill -9`'d restore, say) is removed and the tick proceeds.

## License

MIT
