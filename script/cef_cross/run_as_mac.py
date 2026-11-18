#!/usr/bin/env python3
"""Runs a CEF tool as if on an arm64 Mac, for a cross build on Linux.

Usage: run_as_mac.py CEF_DIR TOOL.py [ARGS...]

TOOL.py is a script in CEF_DIR/tools, such as gclient_hook.py (version headers,
patches, gn gen) or make_distrib.py. Both pick the target from the host
platform, so the platform is reported as darwin/arm64.
"""

import os
import platform
import runpy
import sys

cef_dir = os.path.abspath(sys.argv[1])
tools = os.path.join(cef_dir, "tools")
script = os.path.join(tools, sys.argv[2])
sys.platform = "darwin"
platform.machine = lambda: "arm64"
os.chdir(cef_dir if sys.argv[2] == "gclient_hook.py" else tools)
sys.path.insert(0, tools)
sys.argv = [script] + sys.argv[3:]
runpy.run_path(script, run_name="__main__")
