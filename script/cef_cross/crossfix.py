#!/usr/bin/env python3
"""Local edits so a mac/arm64 CEF or Chrome engine tree generates and builds on a
Linux x64 host.

Usage: crossfix.py CHROMIUM_SRC

Idempotent. Run after CEF is copied into src/cef and before CEF's hook, or on
the Chrome engine's tree before gn gen.
These edits only make the cross build possible; they are not OpenArc changes,
so they stay out of Chromium/chromium_src.
"""

import pathlib
import sys

src = pathlib.Path(sys.argv[1])


def edit(relative, old, new, marker, count=1, needed_while=None):
    path = src / relative
    if not path.exists():
        # The Chrome engine's tree has no src/cef.
        print(f"{relative}: not in this tree")
        return
    text = path.read_text()
    if marker in text:
        print(f"{relative}: already fixed")
        return
    if needed_while is not None and needed_while not in text:
        print(f"{relative}: fixed upstream")
        return
    found = text.count(old)
    if found < count:
        raise SystemExit(f"error: {relative}: expected text not found")
    path.write_text(text.replace(old, new))
    print(f"{relative}: fixed {found}")


# 1. CEF forces enable_cdm_host_verification; the Linux host toolchain asserts
#    on it. Host-toolchain tools never verify CDMs.
edit(
    "media/media_options.gni",
    "assert(!enable_cdm_host_verification || is_mac || is_win,",
    """# Linux-host cross build of a mac target: host-toolchain tools never verify CDMs.
if (enable_cdm_host_verification && !is_mac && !is_win &&
    current_toolchain != default_toolchain) {
  enable_cdm_host_verification = false
}

assert(!enable_cdm_host_verification || is_mac || is_win,""",
    "Linux-host cross build",
)

# 2. cef/BUILD.gn names hermetic_xcode_path, which Chromium made private. Only
#    the sample apps' .xib files use it. CEF fixed it itself from branch 8127.
edit(
    "cef/BUILD.gn",
    "\n          hermetic_xcode_path,\n",
    '\n          rebase_path("//build/mac_files/xcode_binaries", root_build_dir),\n',
    'rebase_path("//build/mac_files/xcode_binaries"',
    needed_while="hermetic_xcode_path",
)

# 3. A cross build ships snapshot_blob.bin instead of the context snapshot,
#    which needs a target binary to run on the host. Bundle data listing it
#    needs a public dep on the action that makes it.
snapshot = 'sources += [ "$root_out_dir/snapshot_blob.bin" ]'
for relative in ["cef/BUILD.gn", "chrome/BUILD.gn", "content/shell/BUILD.gn"]:
    edit(
        relative,
        snapshot,
        snapshot + '\n        public_deps += [ "//v8:run_mksnapshot_default" ]',
        "//v8:run_mksnapshot_default",
    )
