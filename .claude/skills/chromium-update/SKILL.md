---
name: chromium-update
description: Move OpenArc to a new CEF/Chromium release that the automation built on the Linux build host - merge the Chromium/chromium_src overrides, pull the export, fix API changes, verify, publish a Beta and report to the owner. Use when a thread says a new Chromium build is ready, or when asked to update Chromium or CEF.
---

# Chromium update

The automation (`docs/chromium-updates.md`) found a new stable CEF, built it on the Linux build host and started this thread in a worktree on `tech/chromium-<version>`, based on `main`. Your job ends with a Beta release and a Telegram message to the owner. The stable channel waits for the owner's OK.

Read first: `docs/chromium-updates.md`, `docs/cef-build.md`, `docs/cef-smoke-test.md`, `docs/releasing.md`, `AGENTS.md`, and `LOCAL.md` in the main checkout when it exists (`$(git rev-parse --git-common-dir)/../LOCAL.md`); its rules apply to every file, commit and release text you write.

Run every command from this worktree. Never run `fetch` or `all` with `script/cef_remote_build.sh`: the host tree is already at the new base, and `fetch` would move it. Never build CEF on the Mac.

## 1. Read the status

```bash
script/chromium_watch.sh status          # --json for every field
script/chromium_watch.sh log             # end of the host log
```

- `result: failed`: read the log (`LINES_SHOWN=200 script/chromium_watch.sh log`). Fix the cause in `script/cef_cross` (a cross-build fix in `crossfix.py`, a changed CEF flag), commit it, land it on `main` (step 9 says how), then `script/chromium_watch.sh retry` and stop: the next check builds again. Tell the owner what failed and what you changed (step 10's `notify`).
- `result: built`: every override merged cleanly; go to step 2 and only review.
- `result: conflicts`: the build used the upstream file for each path in `conflicts`, so those OpenArc changes are missing from it until you rebuild.

Note `base` (the old version), `cef_version`, `chromium_tag`, `work_dir` and `merge` (one state per override).

## 2. Merge the overrides

```bash
script/chromium_watch.sh merged          # the host's merged set into Chromium/chromium_src
git diff --stat -- Chromium/chromium_src
```

Every file in `Chromium/chromium_src` is a full copy of an upstream file (Chromium with CEF's patches, or CEF itself) with OpenArc's changes; `cef/patch/patches/*.patch` are CEF's own patches with OpenArc's changes folded in. The host merged each override three ways: `old-upstream` (the file at the old base), `openarc` (the override), `new-upstream` (the file at the new base). On the host, `<work_dir>/base/<path>` and `<work_dir>/theirs/<path>` hold the two upstream files; `ssh wsl cat <work_dir>/base/<path>` or `rsync` them here to diff.

For each override, by its `merge` state:

| State | What to do |
| --- | --- |
| `upstream-unchanged`, `same-as-upstream`, `merged` | Read `git diff` of the file anyway. A clean text merge can still be wrong where upstream changed the code around an OpenArc change. |
| `conflict` | Resolve the diff3 markers. |
| `removed-upstream`, `no-base` | Upstream moved or deleted the file: find where the code went in the new tree (`ssh wsl 'cd ~/cef-mac/chromium/src && git grep -n <symbol>'`), move the override there and delete the old one. |
| `patch-does-not-apply` | The merged CEF patch does not apply; see "CEF patch overrides" below. |

Keep every OpenArc behavior. Before resolving a file, learn what OpenArc changed and why:

```bash
diff -u <(ssh wsl cat <work_dir>/base/<path>) <(git show main:Chromium/chromium_src/<path>)  # OpenArc's changes
git log --follow --format='%h %s' -- Chromium/chromium_src/<path>                          # their intent
git log --follow -p -- Chromium/chromium_src/<path>                                        # details
```

Then apply each OpenArc change to the new upstream code. When upstream rewrote the code an OpenArc change touched, port the behavior to the new code, not the old lines. Drop an OpenArc change only when upstream now does the same thing, and say so in the commit message. No conflict markers may remain: `grep -rlE '^(<<<<<<<|=======|>>>>>>>)( |$)' Chromium/chromium_src` prints nothing.

### CEF patch overrides

A changed `cef/patch/patches/<name>.patch` takes effect only through `prepare`. Rebuild it from the tree instead of editing hunks: with the other overrides in place on the host, edit the files the patch covers in `~/cef-mac/chromium/src`, then `ssh wsl 'cd ~/cef-mac/chromium/src/cef && python3 tools/patch_updater.py --resave --patch <name>'` and copy `~/cef-mac/chromium/src/cef/patch/patches/<name>.patch` back into the override.

## 3. Rebuild on the host

Needed when step 2 changed any file the build did not use: every resolved conflict, every edited clean merge.

```bash
WAIT=1 ./script/cef_remote_build.sh prepare    # only when cef/patch changed
WAIT=1 ./script/cef_remote_build.sh build      # pushes Chromium/chromium_src, incremental, minutes
WAIT=1 ./script/cef_remote_build.sh package
```

A compile error in an override: fix the override here and run `build` again. `build` refuses to start while the host's tmux session runs; `./script/cef_remote_build.sh status` shows what runs.

## 4. Bring the export to this worktree

```bash
./script/cef_remote_build.sh pull              # ThirdParty/cef/export-<version> in the main checkout
./script/cef_remote_build.sh use <version>     # only this worktree builds against it
./script/cef_remote_build.sh exports
```

`<version>` is the CEF version number, such as `156.0.33`. Other checkouts keep the shared export until step 9.

## 5. Fix API changes and build

```bash
diff -ru "$(git rev-parse --path-format=absolute --git-common-dir)/../ThirdParty/cef/export/include" ThirdParty/cef/export/include | less
./build.sh build
```

Fix every error and every warning in OpenArc's code (`Sources/`, the CEF bridge); a warning-free build is the bar. Run SwiftFormat with the repository `.swiftformat` on each Swift file you changed. Then:

```bash
./build.sh test
./build.sh ios-build     # the iOS app shares the sync core; it must still build
```

## 6. Smoke test the engine

```bash
script/cef_smoke_test.sh .build/xcode/Build/Products/Debug/OpenArc.app
script/cef_smoke_test.sh .build/xcode/Build/Products/Debug/OpenArc.app --fresh-identity
```

Every FAIL is yours to fix before a release. Keep each WARN and SKIP with its reason for the message in step 10. Do not launch OpenArc itself.

## 7. Version, credits and docs

- Base version text: the CEF and Chromium versions in `docs/cef-build.md` (the base line and the "Moving the base" example), `AGENTS.md` (the baseline rule), `Chromium/README.md`, `script/chromium_source.sh` (`FALLBACK_CEF_CHECKOUT`, `FALLBACK_CHROMIUM_CHECKOUT` and its help text) and the CEF version in `Sources/Browser/Resources/Credits.html`. `git grep` the old version strings to find them all. Refresh the CEF license text in `Credits.html` if the new export's `CREDITS.html` changed it.
- Build number: Sparkle compares `CURRENT_PROJECT_VERSION`. Set it in `project.yml` to one more than the highest of `main`'s value and every published release's build (`gh release list --repo levochkaa/OpenArc --limit 20`; tags read `v<version>-<build>`). Keep `MARKETING_VERSION` unless the owner asks.

## 8. Commit

Focused commits, for example `tech(cef): move the base to cef 156.0.33` (merged overrides, base text, credits) and `fix(cef): ...` for each API fix that needs its own explanation. Follow AGENTS.md's commit rules and attribution, and check the staged diff and message against LOCAL.md's grep before each commit.

## 9. Publish the Beta and land

Write release notes for people who use the app: which Chromium version OpenArc now runs on, that it brings Chromium's security fixes, and any visible change. Then, from this worktree:

```bash
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
SPARKLE_UPDATES_DIR="$MAIN/.build/releases/sparkle-updates" \
  ./script/create_sparkle_release.sh --repo levochkaa/OpenArc --prerelease --notes <notes.md>
```

`SPARKLE_UPDATES_DIR` keeps the earlier archives, so the appcast gets deltas. `--prerelease` reaches only the Beta channel. Never publish without it here.

Land on `main`: rebase this branch onto `main`, fast-forward `main` in the main checkout (it stays checked out on `main`; `git -C "$MAIN" merge --ff-only <branch>`), point this worktree back at the shared export (`ln -sfn "$MAIN/ThirdParty/cef/export" ThirdParty/cef/export`), then make the new export the shared one: `"$MAIN/script/cef_remote_build.sh" install <version>` (the old export stays as `export-<old version>`). Do not push unless the owner asked.

Release the watcher's hold so a newer version can start: `script/chromium_watch.sh done --result released --note "<tag>"`.

## 10. Tell the owner, then stop

```bash
script/chromium_watch.sh notify "<message>"
```

Write the message in the owner's language from the thread's instructions. Include: the old and new CEF/Chromium versions, the release tag and that it is on Beta only, which overrides needed hand merges and what changed in them, the API fixes, the smoke test's WARN/SKIP lines, and what to check by hand:

- passkeys sign in with Touch ID (only a Developer ID build has the keychain group);
- a site's notification prompt, then macOS's own prompt, and a delivered notification;
- screen sharing from a site with a real permission decision;
- an extension popup and extension tab APIs (the `chrome/browser/extensions` overrides);
- each behavior whose override you resolved by hand, named concretely;
- media and video playback on a real site, printing, translation.

End with: reply OK to promote it to stable. Then stop. Do not promote without that reply.

## Promote to stable (only after the owner's OK)

```bash
gh release edit <tag> --repo levochkaa/OpenArc --prerelease=false --latest
curl -s https://api.openarc.su/appcast.xml | grep -o 'sparkle:version="[0-9]*"'   # shows the new build
```

Then notify the owner that it is on stable.

## Roll back

- Shared export: `./script/cef_remote_build.sh install <old version>` in the main checkout swaps back; `exports` lists what is kept.
- Code: `git revert` the update's commits on `main`.
- A Beta with a bad engine: publish a fixed build with a higher build number on Beta (roll forward; Sparkle never offers a lower build). Build it against the old export after `install <old version>` when the new engine cannot be fixed quickly, and tell the owner.
- An update you abandon: `script/chromium_watch.sh done --result abandoned --note "<why>"`, and tell the owner.
