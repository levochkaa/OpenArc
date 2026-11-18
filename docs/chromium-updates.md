# Chromium updates

OpenArc follows stable Chromium as closely as the build allows. A watcher on the Linux build host starts the CEF build as soon as a new stable appears; when it finishes, the Mac starts an agent thread that adapts OpenArc, verifies it and publishes a Beta. The stable channel gets the release only after the owner checks the Beta and says OK.

```text
Linux build host, every 30 min              Mac, every 5 min                     Agent thread
check: newer stable?  ── yes ──> pipeline   mac-tick: push main's tools,         chromium-update skill:
  (CEF builds index,             snapshot     read host status ── built ──>      merge overrides, rebuild,
   CEF branch head)              fetch        start one thread per version       pull, build, test, smoke,
                                 merge                                           Beta, Telegram, stop
                                 prepare
                                 build, package ── status.json
```

## What counts as new

`script/cef_cross/chromium_watch.py check` compares against the baseline, the version of the Mac's `ThirdParty/cef/export` (pushed to the host by the Mac as `baseline.json`):

- the newest `stable` macOS arm64 build in `https://cef-builds.spotifycdn.com/index.json`: a newer Chromium, or a CEF fix release on the same Chromium;
- the head of that stable CEF branch on GitHub, when its `CHROMIUM_BUILD_COMPATIBILITY.txt` already names a newer Chromium than the index has. CEF updates the branch hours before the CDN builds it, so this starts patch updates earlier.

CEF beta branches are never built. `status` shows Chrome's own stable version for reference.

Each version is attempted once. While an update waits for its agent (`hold`), the watcher starts nothing newer; it sends one message that a newer version is waiting. `done` releases the hold.

## The pipeline on the host

`check` starts `chromium_watch.py run` in the build tmux session (`openarc-cef`, the same one `script/cef_remote_build.sh` uses, so the two never build at once). The log is `~/cef-mac/logs/update-<key>.log`, also `logs/latest.log`, so `./script/cef_remote_build.sh status` and `wait` follow it.

| Phase | What happens |
| --- | --- |
| `snapshot-base` | Writes each overridden file as the old base had it: the Chromium file with the old CEF's patches applied (`git apply` of each `patch/patches/*.patch` that touches it), or the CEF file. |
| `resolve` | Resolves the CEF commit on its branch. |
| `fetch` | `cef_cross.sh fetch` at the new CEF commit and Chromium tag; `out/` is kept, so the build is incremental where it can be. |
| `merge` | The same snapshot at the new base, then `git merge-file --diff3` per override: old upstream, OpenArc's override, new upstream. `merged/` is the new `Chromium/chromium_src`, conflicts with markers; `build/` holds what merged cleanly. |
| `prepare` | `cef_cross.sh prepare` with `build/`. When a merged CEF patch override does not apply, it prepares again with CEF's own patch and marks the override `patch-does-not-apply`. |
| `build`, `package` | `cef_cross.sh build` and `package` with `build/`. A conflicting override is left out, so the build keeps the upstream file and finishes; the agent resolves it and rebuilds incrementally. |

The status file is `~/.local/state/openarc-automation/status.json` on the host: version, base, phase, `result` (`running`, `built`, `conflicts`, `failed`, then `released` or `abandoned`), conflicts, the merge state of every override, timings per phase, log and work directory. The work directory (`updates/<key>/` next to it) keeps `base/`, `theirs/`, `merged/`, `build/` and `merge.json`.

## The Mac side

The LaunchAgent runs `chromium_watch.py mac-tick` from the main checkout:

1. When the host is idle, pushes `main`'s committed `script/cef_cross` and `Chromium/chromium_src` and the export's version to `~/cef-mac/openarc/main` on the host. The watcher and its timer run from that copy, so uncommitted work never reaches an automatic build. Manual `cef_remote_build.sh` steps keep using `openarc/tools` and `openarc/chromium_src`.
2. Reads the host's status over ssh.
3. For a `built` or `conflicts` result it has not seen, starts one T3 thread in this project, in a new worktree on `tech/chromium-<version>` from `main`, told to follow the `chromium-update` skill (`.claude/skills/chromium-update/SKILL.md`). Its state is `~/Library/Application Support/OpenArc-Automation/chromium-update.json`; a lock keeps two ticks from starting two threads.

Its log is `~/Library/Logs/OpenArc-Automation/chromium-update.log`.

## Messages

Telegram messages go through the bot in `KODYA_BOT_TOKEN` to `KODYA_CHAT_ID`, read from the environment or `~/.env` on each machine and never printed: the build starts, a build fails (with the end of the log), the agent thread starts (with its link), a newer version waits behind an open update, and the agent's Beta message with the checks to do by hand. `OPENARC_AUTOMATION_NO_NOTIFY=1` turns them off.

## Install

Land the automation on `main` first: the LaunchAgent runs the main checkout, and the host runs `main`'s copy.

```bash
./script/automation_install.sh install --dry-run   # prints the plist, the units and the commands
./script/automation_install.sh install             # LaunchAgent + host timer
./script/automation_install.sh status
./script/automation_install.sh uninstall           # state and logs stay
```

`install` pushes `main` to the host, writes `~/.config/systemd/user/openarc-chromium-watch.{service,timer}` there and enables the timer, and loads `~/Library/LaunchAgents/com.levochkaa.OpenArc.chromium-update.plist`. The host needs lingering (`loginctl enable-linger`) so the timer runs without a login. The Mac needs `t3` with the T3 server running, and ssh to the host without a prompt.

## By hand

```bash
script/chromium_watch.sh status                       # on the host, over ssh
script/chromium_watch.sh check --dry-run              # what would start, then the read-only first phases
script/chromium_watch.sh check --dry-run --baseline 156.0.30+g6028375+chromium-156.0.8078.96
script/chromium_watch.sh retry                        # build the last version again
script/chromium_watch.sh done --result abandoned --note "why"
script/chromium_watch.sh notify --test                # a message labelled as a test
```

`check --dry-run` changes no state and stops before `fetch`; with an older `--baseline` its first phase fetches that Chromium tag's objects into `refs/openarc/base` of the host checkout, which leaves the working tree alone.

Host and paths follow `script/cef_remote_build.sh`: `OPENARC_CEF_REMOTE_HOST` (default `wsl`) and `OPENARC_CEF_REMOTE_ROOT` (default `~/cef-mac`). `OPENARC_AUTOMATION_STATE_DIR` moves the state directory, `OPENARC_AUTOMATION_INTERVAL` sets the Mac's interval at install.
