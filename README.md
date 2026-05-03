# tmux-resurrect-launchd

A macOS [launchd](https://www.launchd.info/) job that periodically snapshots tmux state via [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), with an interactive picker for recovering after a crash. Built because [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum)'s autosave doesn't fire reliably under iTerm2 `tmux -CC` (see [Background](#background)).

## Install

Requires macOS, [tmux](https://github.com/tmux/tmux) on PATH, and [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) at `~/.tmux/plugins/tmux-resurrect/`.

```bash
git clone https://github.com/omriariav/tmux-resurrect-launchd.git
cd tmux-resurrect-launchd
./install.sh
```

The installer drops three binaries into `~/.local/bin/` (`tmux-resurrect-save`, `tmux-resurrect-restore`, `tmux-resurrect-precheck`), registers `com.user.tmux-resurrect-save` with launchd (default interval **15 minutes** — edit `StartInterval` in the plist and re-run to change), and prompts to wire the [shell-rc nudge](#shell-rc-nudge). Logs to `~/Library/Logs/tmux-resurrect-save.log`. The first save fires at install time so you can see proof of life.

> **If you already use `tmux-continuum`**, silence its autosave to avoid racing this daemon over the same snapshot. Set `set -g @continuum-save-interval '0'` in `~/.tmux.conf`. Continuum's other behaviors (auto-restore on start) are unaffected.

## Recovery

After a crash or reboot, from a fresh non-tmux shell:

```bash
tmux-resurrect-restore
```

That opens an interactive picker:

```
Snapshots in ~/.tmux/resurrect (newest first; * = current 'last'):

*  1) 05-03 15:09  3m ago     3s/ 11p     2K  amq-squad,beta-vault-context,main
   2) 05-03 14:54  18m ago    3s/ 16p     2K  amq-squad,beta-vault-context,main
       ─────────── boot 2026-05-03 14:40 ───────────
   3) 05-03 14:30  41m ago    3s/ 16p    25K  amq-squad,beta-vault-context,main
   4) 05-03 14:15  56m ago    3s/ 16p    25K  amq-squad,beta-vault-context,main
   ...

  recommended: 3 (newest pre-boot snapshot with >= 3 panes)

Pick a number [3], a timestamp, "latest-good", or q to quit:
```

The horizontal rule is your macOS last-boot time, so the post-crash regression is visually separated from the pre-crash state. Press Enter to take the recommendation.

### Non-interactive forms

```bash
tmux-resurrect-restore --list                     # machine-readable rows; safe inside tmux
tmux-resurrect-restore --restore latest-good      # newest snapshot with >= 3 panes
tmux-resurrect-restore --restore 20260503T143047  # explicit timestamp
tmux-resurrect-restore --restore latest-good --no-confirm
```

`--list` is the only mode that runs inside tmux — anything else would have to kill the server you're sitting in, so the script refuses early.

### What the restore does

Drops a `~/.tmux/resurrect/.restoring` fence so the next save tick can't race it, stops the launchd job, kills the current tmux server (with confirmation), repoints `~/.tmux/resurrect/last`, starts a fresh detached server, runs `tmux-resurrect`'s `restore.sh` through `tmux run-shell`, drops the bootstrap session, re-arms the launchd job, and removes the fence. Reattach with iTerm2's `tmux -CC attach -t <session>`.

### If a restore aborts mid-flight

The cleanup trap is phase-aware. The launchd job is **only** re-armed when the restore completes successfully — a tick after a half-finished restore would otherwise save the bootstrap state as the new `last` and overwrite your snapshot. On any abort, the job is intentionally left unloaded, the fence is removed, and the script prints recovery instructions specific to where it got to:

| How far it got                         | What you have                       | Next step                                                                 |
|----------------------------------------|-------------------------------------|---------------------------------------------------------------------------|
| Stopped the launchd job, nothing else  | server intact; job off              | `launchctl load -w ~/Library/LaunchAgents/com.user.tmux-resurrect-save.plist` |
| Killed the server, didn't start a new one | no server; job off               | `tmux new-session -d -s recovery && tmux-resurrect-restore` (retry)       |
| Started a new server, didn't restore   | bootstrap session only; job off     | `tmux kill-server && tmux-resurrect-restore` (retry)                      |
| Restored, didn't finish cleanup        | sessions restored; job off          | inspect with `tmux ls`; if good, `launchctl load -w` the plist            |

## Shell-rc nudge

Run `tmux-resurrect-precheck` from your shell rc and on every new shell — outside tmux — it prints up to two short lines if something needs your attention:

- 🟡 **yellow** — saved sessions exist that aren't currently running. The action is `tmux-resurrect-restore`. This is the post-crash hint.
- 🔴 **red** — the latest save **failed** silently (e.g., the tmux-resurrect plugin disappeared, or `save.sh` ran but didn't advance `last`). The action is to look at the log. Not dismissable: a broken save daemon should keep nagging.

Both lines are silenced by `TMUX_RESURRECT_QUIET=1` in your environment.
The yellow line can be dismissed for 24h: `tmux-resurrect-precheck --dismiss`.
Run `tmux-resurrect-precheck --help` for the silence/dismiss options.

The installer wires it idempotently as a managed block:

```sh
# >>> tmux-resurrect-launchd >>>
[ -x "$HOME/.local/bin/tmux-resurrect-precheck" ] && "$HOME/.local/bin/tmux-resurrect-precheck"
# <<< tmux-resurrect-launchd <<<
```

Re-run `./install.sh --precheck` to add it later. `./uninstall.sh` strips the block.

## Regression guard

`tmux-resurrect-save` protects `~/.tmux/resurrect/last` against silent overwrites. After each save it compares the new snapshot's pane count to the prior `last`. If a meaningful state (≥ 2 panes) was replaced by a degenerate one (≤ 1 pane), the new timestamped file is kept on disk for forensics but `last` is reverted. This is the post-Mac-reboot case: a fresh tmux server starts saving its empty default session over your real recovery point. The guard preserves the recovery point until you run `tmux-resurrect-restore`.

If you legitimately tear down sessions to one pane and want the new state to stick:

```bash
touch ~/.tmux/resurrect/.allow_regression   # one-time bypass; sentinel auto-removed
```

## Verify

```bash
launchctl list | grep tmux-resurrect-save     # should print the label
tail ~/Library/Logs/tmux-resurrect-save.log   # most recent saves and their status
tmux-resurrect-restore --list | head          # snapshot inventory
```

## Uninstall

```bash
./uninstall.sh
```

Removes the launchd job, the plist, the three binaries, and the precheck managed block from `~/.zshrc` / `~/.bashrc` / `~/.bash_profile`. Refuses to edit an rc that has a start marker but no end marker (would otherwise nuke everything below the start), and writes via `cat > "$rc"` rather than `mv` so a symlinked dotfile keeps its inode. Snapshots in `~/.tmux/resurrect/` and the log are left alone — `rm` manually if you want.

## Background

`tmux-continuum` triggers periodic saves by embedding a shell call (`#(continuum_save.sh)`) in tmux's `status-right`. tmux re-renders `status-right` on every `status-interval` tick, which is what gives continuum its heartbeat. That mechanism doesn't fire reliably under iTerm2's [`tmux -CC` control mode](https://iterm2.com/documentation-tmux-integration.html): in control mode iTerm renders the chrome itself and tmux's status bar isn't drawn the usual way, so the embedded shell call never runs. Continuum effectively saves once at session start and goes silent.

This daemon sidesteps the status-bar mechanism entirely: launchd runs `tmux-resurrect`'s save script on a fixed schedule, regardless of how (or whether) anything is attached.

Related upstream issues:
- [tmux-continuum #40 — Does continuum work with iTerm2 -CC?](https://github.com/tmux-plugins/tmux-continuum/issues/40)
- [tmux-continuum #42 — Autosave doesn't work, `#{continuum_status}` is empty](https://github.com/tmux-plugins/tmux-continuum/issues/42)
- [tmux-resurrect #68 — Can this be cron'ed?](https://github.com/tmux-plugins/tmux-resurrect/issues/68)

### Implementation notes

`tmux-resurrect-save` is a small shell script with three load-bearing details that are easy to get wrong (see comments in `bin/tmux-resurrect-save` for the full reasoning):

- **`tmux run-shell` wrapping.** `save.sh` is invoked via `tmux run-shell`, not directly. Without an attached client, tmux's `display-message` mangles tab delimiters and `save.sh` writes 12-byte snapshots containing only `state_main_`. The same fix applies to the restore path — `tmux-resurrect-restore` runs the plugin's `restore.sh` through `tmux run-shell` so `$TMUX` is populated and the resurrect plugin's `tmux_socket()` helper returns non-empty.
- **Explicit `PATH` and literal `$HOME`.** launchd runs jobs with a minimal `PATH` that omits `/opt/homebrew/bin`, and doesn't reliably propagate `$HOME` through `/bin/sh`. Both are baked into the installed binary at install time.
- **Named binaries, not inline `sh -c`.** All three scripts have real names so they show up identifiably in `ps`, Activity Monitor, and macOS's Background Items panel.

The save/restore coordination uses three sentinel files under `~/.tmux/resurrect/`:

- `.restoring` — created by `tmux-resurrect-restore`, removed when it finishes. While present, the save tick skips. Auto-cleared after 10 minutes (fail-open).
- `.allow_regression` — manually created to bypass the regression guard once. Removed after consultation.
- `.last_status` — written by every save tick (`status<TAB>epoch<TAB>detail`). Read by `tmux-resurrect-precheck` to surface silent failures.

## License

MIT
