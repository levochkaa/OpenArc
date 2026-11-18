# Building CEF

OpenArc runs on its own CEF build: CEF plus the overrides in `Chromium/chromium_src`. The app builds against a binary distribution in `ThirdParty/cef/export`; it needs no Chromium checkout on the Mac.

The current base is CEF 156.0.31+ge603d97, Chromium 156.0.8078.100, recorded in `ThirdParty/cef/export/include/cef_version.h`. Routine rebuilds stay on that base; move it only on purpose.

## The Linux build host

CEF is built on a Linux x64 machine and copied to the Mac. A build there does not load the Mac, and an incremental override rebuild takes minutes instead of tying up a laptop. `script/cef_remote_build.sh` drives it over ssh from the Mac:

| Step | Command | Notes |
| --- | --- | --- |
| SDK | `./script/cef_remote_build.sh xcode` | Copies the macOS 26.5 SDK of Xcode 26.6 to the host's hermetic Xcode. Once per Xcode. |
| Sources | `./script/cef_remote_build.sh fetch` | Checks out CEF and Chromium with macOS dependencies. Once per base, about an hour. |
| Configure | `./script/cef_remote_build.sh prepare` | Copies CEF into `src/cef` with OpenArc's CEF patch overrides, applies the cross-build fixes, runs CEF's hook (patches, version headers, `gn gen`). |
| Build | `./script/cef_remote_build.sh build` | Copies `Chromium/chromium_src` over the tree and builds `cef_framework`. Incremental. |
| Package | `./script/cef_remote_build.sh package` | Makes the minimal binary distribution: `include/`, `libcef_dll/`, `cmake/`, `CMakeLists.txt`, `CREDITS.html`, `Release/Chromium Embedded Framework.framework`. |
| Copy | `./script/cef_remote_build.sh pull` | rsyncs the distribution to `ThirdParty/cef/export-<version>` (such as `export-156.0.31`) in the primary checkout, strips local symbols with Xcode 26.6's `strip -x`, links `Debug` to `Release` and adds the `.openarc-chromium-fork` marker. |
| Switch | `./script/cef_remote_build.sh install <version>` | Makes `export-<version>` the shared export and moves the previous one to `export-<its version>` (`-previous` when it is the same version). Installing the old version swaps back. `exports` lists them. |

`all` runs prepare, overrides, build and package. Remote steps run in a tmux session on the host, so a dropped connection does not stop them. `status` shows the end of the log and `wait` waits for the step to finish; `WAIT=1` makes the step itself wait.

`use <version>` points only the current checkout's `ThirdParty/cef/export` link at `export-<version>`, which tries a new base in one worktree while the others keep the shared export.

After the export changes, run `./build.sh build`, `./build.sh test` and the engine smoke test ([cef-smoke-test.md](cef-smoke-test.md)).

On the WSL host (24 threads, 52 GB) the first build of a new base took about 1.5 hours; an override rebuild with the framework's ThinLTO link takes 1.5 to 5 minutes, packaging about a minute, and `pull` seconds over the LAN.

### After changing an override

```bash
WAIT=1 ./script/cef_remote_build.sh build
WAIT=1 ./script/cef_remote_build.sh package
./script/cef_remote_build.sh pull
./script/cef_remote_build.sh install 156.0.31   # export-156.0.31 becomes the export; the old one is kept as export-156.0.31-previous
./build.sh build
```

A change to `Chromium/chromium_src/cef/patch` needs `prepare` before `build`.

### Moving the base

Pick the CEF commit and its Chromium tag from CEF's `CHROMIUM_BUILD_COMPATIBILITY.txt`, then:

```bash
export CEF_BRANCH=8078 CEF_COMMIT=e603d97dd5cb8b0e37d8f1daa2bc5c7eab1aa7a5 CHROMIUM_TAG=156.0.8078.100
WAIT=1 ./script/cef_remote_build.sh fetch
WAIT=1 ./script/cef_remote_build.sh all
```

Before `all`, rebase every override on the new base: each file in `Chromium/chromium_src` is a full copy of a Chromium or CEF source with OpenArc's changes, so diff the old base's file against the override to find the changes, and three-way merge them onto the new file. `cef/patch/patches/*.patch` are CEF's own patches with OpenArc's changes folded in; regenerate one with CEF's `tools/patch_updater.py --resave --patch <name>` after the overrides are in the tree. Then update the base in this file, in `AGENTS.md` and in `script/chromium_source.sh`'s fallbacks, and the CEF version in `Sources/Browser/Resources/Credits.html`.

### Host layout

`OPENARC_CEF_REMOTE_HOST` (default `wsl`) and `OPENARC_CEF_REMOTE_ROOT` (default `~/cef-mac`) choose the host and the build root. Under the root:

- `depot_tools/`, `cef/` (the CEF checkout), `chromium/src/` (Chromium, with CEF copied into `src/cef`).
- `xcode_binaries/`: the hermetic Xcode, a macOS SDK and Xcode's `version.plist`, linked from `src/build/mac_files/xcode_binaries`. Chromium checks the SDK version it expects in `build/config/mac/mac_sdk.gni`.
- `openarc/tools/` and `openarc/chromium_src/`: copies of `script/cef_cross` and `Chromium/chromium_src`, refreshed by every remote step.
- `out`: `chromium/src/out/Release_GN_arm64`; `artifacts/dist/`: the last distribution; `logs/`: one log per step.

The build uses the Mac build's GN arguments (official, PGO, ThinLTO, proprietary codecs, no DCHECKs) with `target_os=mac use_system_xcode=false`.

### What differs from a Mac build

- `script/cef_cross/crossfix.py` edits the tree so a Linux host can build a mac target: it turns off CDM host verification for host-toolchain tools, replaces CEF's use of Chromium's private `hermetic_xcode_path`, and makes bundles that list `snapshot_blob.bin` depend on the action that makes it. These edits are not OpenArc changes and stay out of `Chromium/chromium_src`.
- `script/cef_cross/run_as_mac.py` runs CEF's `gclient_hook.py` and `make_distrib.py` with the platform reported as an arm64 Mac.
- Only `cef_framework` is built: the sample apps need `ibtool`, which Linux lacks. `make_distrib` takes the framework from a stand-in `cefclient.app`.
- Chromium builds the V8 context snapshot only on a macOS host, since it runs a target binary. The cross-built framework ships `snapshot_blob.bin` instead of `v8_context_snapshot.arm64.bin` and loads it; the app stages the framework's resources as they are.
- Only Release is built. `Debug` in the export links to `Release`; the app stages Release CEF for Debug builds too.

## Building on a Mac

`./script/chromium_source.sh` still checks out and builds CEF on a Mac with Xcode 26.6 (`package Debug Release` once, then `apply-overrides` and `build Release` for override changes). It needs about 70 GB and several hours.
