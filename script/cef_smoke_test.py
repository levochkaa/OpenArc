#!/usr/bin/env python3
"""Runtime smoke test for OpenArc's engine. Run through script/cef_smoke_test.sh."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import fcntl
import glob
import http.server
import json
import os
import plistlib
import random
import re
import shutil
import signal
import socketserver
import sqlite3
import string
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "script" / "cef_smoke_test" / "fixtures"
CEF_VERSION_HEADER = ROOT / "ThirdParty" / "cef" / "export" / "include" / "cef_version.h"
SUPPORT = Path.home() / "Library" / "Application Support" / "OpenArc"
CRASH_DIRS = [Path.home() / "Library" / "Logs" / "DiagnosticReports"]
COPY_BUNDLE_ID = "com.levochkaa.OpenArc.smoketest"
COPY_NAME = "OpenArc Smoke"
COPY_DIR = Path.home() / "Library" / "Caches" / "OpenArcSmokeTest"
# Every run uses the same copy path, bundle id and defaults domain, so runs from other checkouts wait for this lock.
RUN_LOCK = COPY_DIR / "run.lock"
CHROME_ENGINE_FRAMEWORK = "OpenArc Framework.framework"
LADYBIRD_ENGINE_FRAMEWORK = "OpenArc Ladybird.framework"
# Checks of features the Chrome engine does not have yet (docs/chrome-engine.md); they skip on it.
CHROME_ENGINE_GAPS = {
    "extension-sees-tabs": "extensions also see the blank tab of the engine's hidden window",
    "screen-share-picker": "OpenArc's screen share picker",
    "extension-popup": "extension buttons in OpenArc's toolbar",
    "notification-after-site-permission": "site permission prompts in OpenArc's own card",
    "translate-in-place": "translation",
}
# Checks of what only Chromium has; they skip when the copy runs on WebKit alone (docs/webkit-engine.md).
WEBKIT_ENGINE_GAPS = {
    "extension-sees-tabs": "--load-extension loads a Chromium extension",
    "history": "WebKit pages write no Chromium History database",
    "print-preview": "the agent CLI clicks through DevTools' DOM methods, which WebKit pages lack",
    "screen-share-picker": "the agent CLI clicks through DevTools' DOM methods, which WebKit pages lack",
    "extension-popup": "the toolbar button of a Chromium extension",
    "notification-after-site-permission": "the agent CLI clicks through DevTools' DOM methods, which WebKit "
                                          "pages lack",
    "translate-in-place": "translation is Chromium's",
    "sandbox": "no Chromium process runs",
}
# Utility services Chromium itself starts without a sandbox on macOS: video capture opens the cameras.
UNSANDBOXED_SERVICES = {"video_capture.mojom.VideoCaptureService"}
# Checks of what Ladybird does not have (docs/ladybird-engine.md); they skip when the copy runs on Ladybird.
LADYBIRD_ENGINE_GAPS = {
    "media-devices": "Ladybird has no getDisplayMedia, and the fixture server's http://127.0.0.1 is no secure context "
                     "there",
    "extension-sees-tabs": "--load-extension loads a Chromium extension",
    "passkeys": "Ladybird has no WebAuthn",
    "history": "Ladybird pages write no Chromium History database",
    "print-preview": "the agent CLI clicks through DevTools' DOM methods, which Ladybird pages lack",
    "screen-share-picker": "the agent CLI clicks through DevTools' DOM methods, which Ladybird pages lack",
    "extension-popup": "the toolbar button of a Chromium extension",
    "notification-after-site-permission": "the agent CLI clicks through DevTools' DOM methods, which Ladybird "
                                          "pages lack",
    "translate-in-place": "translation is Chromium's",
}
SYSTEM_TCC = Path("/Library/Application Support/com.apple.TCC/TCC.db")
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/"
              "lsregister")
USER_TCC = Path.home() / "Library" / "Application Support" / "com.apple.TCC" / "TCC.db"

HELP_EPILOG = f"""
What it does:
  Copies the app to {COPY_DIR}/OpenArcSmoke.app, gives it the bundle id
  {COPY_BUNDLE_ID} and the name "{COPY_NAME}", re-signs it with only
  get-task-allow, presets its defaults, and starts it through LaunchServices in
  the background with --no-activate, its own --runtime-suffix and agent socket,
  --use-mock-keychain and the test extension. Fixtures are served from
  127.0.0.1 on random ports. Checks run through the copy's own
  Contents/Resources/bin/openarc; window checks read and press the copy's
  windows in the background with cua-driver. --engine chrome starts the copy on
  the Chrome engine (OpenArc Framework.framework, docs/chrome-engine.md) with
  --openarc-engine=chrome, and checks that its pages run there. --engine webkit
  starts it on WebKit alone (docs/webkit-engine.md) and checks that no Chromium
  loads; checks of Chromium's own features skip. --engine ladybird starts it on
  Ladybird (OpenArc Ladybird.framework, docs/ladybird-engine.md) and checks
  that its pages run in Ladybird's WebContent helpers and no Chromium loads. Afterwards the copy is killed with
  SIGKILL, and its app copy, CEF- and Session- data and defaults are deleted.
  One run at a time: a run waits while another holds {RUN_LOCK} (--wait).

Checks:
  chromium-engine, sandbox, no-notification-request-at-launch, engine-version, page-load-js-navigation,
  webassembly, proprietary-codecs, extension-sees-tabs, passkeys, media-devices, history,
  webkit-engine, print-preview, screen-share-picker, extension-popup,
  notification-after-site-permission, translate-in-place, background-launch,
  stability.

Set up once per Mac (docs/cef-smoke-test.md):
  - Screen Recording for {COPY_BUNDLE_ID}: the picker asks macOS for screens and
    windows, and macOS prompts while the copy has no decision. Until someone
    allows or denies it once (--allow-system-prompts lets the check open the
    picker and the prompt), screen-share-picker skips.
  - Notifications for "{COPY_NAME}" in System Settings > Notifications: with
    them on, notification-after-site-permission also checks delivery.
  - no-notification-request-at-launch is conclusive only while macOS has no
    notification decision for the copy; --fresh-identity gives it a new bundle
    id for one run.

Needs the network: translate-in-place (Google's translation service).

Exit status: 0 when no check failed, 1 when any did, 2 when setup failed.
"""


# MARK: - Small helpers


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run(command: list[str], timeout: float = 60, check: bool = True, env: dict | None = None,
        input_text: str | None = None) -> subprocess.CompletedProcess:
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env, input=input_text)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(command[:3])}… failed ({result.returncode}): {result.stderr.strip()[:400]}")
    return result


def random_token(length: int = 6) -> str:
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(length))


def expected_chrome_major() -> int | None:
    try:
        match = re.search(r"#define CHROME_VERSION_MAJOR (\d+)", CEF_VERSION_HEADER.read_text())
    except OSError:
        return None
    return int(match.group(1)) if match else None


def wait_until(predicate, timeout: float, interval: float = 0.25):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    return last


class CheckFailed(Exception):
    def __init__(self, evidence: str, details: dict | None = None):
        super().__init__(evidence)
        self.evidence = evidence
        self.details = details or {}


class CheckSkipped(Exception):
    def __init__(self, reason: str, details: dict | None = None):
        super().__init__(reason)
        self.reason = reason
        self.details = details or {}


# MARK: - Fixture server


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class FixtureServer:
    def __init__(self, directory: Path):
        handler = lambda *args, **kwargs: QuietHandler(*args, directory=str(directory), **kwargs)  # noqa: E731
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.port}/{path}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


# MARK: - cua-driver


class Cua:
    """Background window reads and presses through the cua-driver daemon."""

    def __init__(self, session: str):
        self.session = session
        self.path = shutil.which("cua-driver")

    @property
    def available(self) -> bool:
        return self.path is not None

    def call(self, tool: str, args: dict, timeout: float = 60) -> dict:
        if not self.path:
            raise CheckSkipped("cua-driver is not installed")
        payload = dict(args)
        payload.setdefault("session", self.session)
        result = run([self.path, "call", tool, json.dumps(payload)], timeout=timeout, check=False)
        text = result.stdout.strip()
        try:
            data = json.loads(text) if text else {}
        except json.JSONDecodeError:
            data = {"raw": text}
        if result.returncode != 0:
            raise RuntimeError(f"cua-driver {tool}: {(result.stderr or text).strip()[:400]}")
        return data

    def windows(self, pid: int) -> list[dict]:
        return self.call("list_windows", {"pid": pid}).get("windows", [])

    def state(self, pid: int, window_id: int, query: str | None = None, screenshot: Path | None = None,
              max_elements: int = 400) -> dict:
        args: dict = {"pid": pid, "window_id": window_id, "max_elements": max_elements, "timeout_ms": 5000}
        if query:
            args["query"] = query
        if screenshot:
            args["screenshot_out_file"] = str(screenshot)
        else:
            args["include_screenshot"] = False
        return self.call("get_window_state", args)

    def screenshot(self, pid: int, window_id: int, path: Path) -> Path | None:
        try:
            self.call("get_window_state", {
                "pid": pid, "window_id": window_id, "include_accessibility_tree": False,
                "screenshot_out_file": str(path),
            })
        except RuntimeError:
            return None
        return path if path.exists() else None

    def press(self, pid: int, window_id: int, token: str) -> dict:
        return self.call("click", {"pid": pid, "window_id": window_id, "element_token": token})

    def end(self) -> None:
        if self.path:
            run([self.path, "call", "end_session", json.dumps({"session": self.session})], check=False, timeout=20)


def tree_rows(state: dict) -> list[tuple[str, str]]:
    """(token, row text) for each row of a markdown tree."""
    snapshot = state.get("snapshot_id", "")
    rows = []
    for line in state.get("tree_markdown", "").splitlines():
        match = re.search(r"\[(\d+)\]", line)
        if match:
            rows.append((f"{snapshot}:{match.group(1)}", line.strip()))
    return rows


def find_row(state: dict, *patterns: str) -> tuple[str, str] | None:
    for token, text in tree_rows(state):
        if all(re.search(pattern, text, re.IGNORECASE) for pattern in patterns):
            return token, text
    return None


# MARK: - One run at a time


class RunLock:
    """An exclusive lock on the copy's place; the kernel drops it when the run's process ends, even on SIGKILL."""

    def __init__(self, path: Path):
        self.path = path
        self.handle = None

    def acquire(self, timeout: float, owner: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+")
        deadline = time.monotonic() + timeout
        announced = False
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not announced:
                    handle.seek(0)
                    log(f"Another smoke run holds {self.path} ({handle.read().strip() or 'no details'}); "
                        f"waiting up to {timeout / 60:g} min …")
                    announced = True
                if time.monotonic() > deadline:
                    handle.close()
                    raise TimeoutError(f"another smoke run still holds {self.path} after {timeout / 60:g} min")
                time.sleep(2)
        handle.seek(0)
        handle.truncate()
        handle.write(json.dumps(owner) + "\n")
        handle.flush()
        self.handle = handle


# MARK: - The isolated copy


class Instance:
    def __init__(self, source_app: Path, out_dir: Path, identity: str | None, extension: Path, engine: str):
        self.source_app = source_app
        self.engine = engine
        self.out_dir = out_dir
        self.identity = identity
        self.extension = extension
        self.suffix = f"cef-smoke-{random_token()}"
        # One fixed place: macOS's notification service ties the bundle id to the
        # app's path and refuses a client whose path moved since it last saw it.
        self.work_dir = COPY_DIR
        self.app = self.work_dir / "OpenArcSmoke.app"
        self.socket = f"/tmp/oa-smoke-{random_token(8)}.sock"
        self._pid: int | None = None
        self.cli_path = self.app / "Contents" / "Resources" / "bin" / "openarc"
        self.started_at = time.time()

    # Setup

    def prepare(self, site_engines: dict[str, str]) -> None:
        # A run that was stopped hard may have left its copy running.
        run(["/usr/bin/pkill", "-9", "-f", str(self.app)], check=False)
        shutil.rmtree(self.app, ignore_errors=True)
        self.work_dir.mkdir(parents=True, exist_ok=True)
        log(f"Copying {self.source_app} …")
        run(["/bin/cp", "-cR", str(self.source_app), str(self.app)], timeout=300)
        contents = self.app / "Contents"
        (contents / "embedded.provisionprofile").unlink(missing_ok=True)
        self._set_identity(contents / "Info.plist", COPY_BUNDLE_ID, COPY_NAME)
        original_id = self._read_plist(self.source_app / "Contents" / "Info.plist").get("CFBundleIdentifier", "")
        helpers = sorted((contents / "Frameworks").glob("*Helper*.app"))
        engine_helpers = sorted(self.engine_framework().glob("Versions/Current/Helpers/*.app"))
        for helper in [*helpers, *engine_helpers]:
            plist = helper / "Contents" / "Info.plist"
            helper_id = self._read_plist(plist).get("CFBundleIdentifier", "")
            if original_id and helper_id.startswith(original_id):
                # The alerts helper's name is what macOS's notification prompt shows.
                self._set_identity(plist, COPY_BUNDLE_ID + helper_id[len(original_id):], COPY_NAME)
        entitlements = self.work_dir / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        identity = self.identity or "-"
        # The Chrome engine's helpers live in its framework, which seals them: helpers first, then the framework.
        engine_bundles = [*engine_helpers, self.engine_framework()] if engine_helpers else []
        for bundle in [*engine_bundles, *helpers, self.app]:
            run(["/usr/bin/codesign", "--force", "--sign", identity, "--entitlements", str(entitlements),
                 "--timestamp=none", str(bundle)], timeout=300)
        self._reset_defaults()
        self._write_default("browser.settings.onboardingCompleted", "-bool", "YES")
        self._write_default("browser.settings.agentAccessEnabled", "-bool", "YES")
        self._write_default("SUEnableAutomaticChecks", "-bool", "NO")
        self._write_default("SUAutomaticallyUpdate", "-bool", "NO")
        # A copy that crashed while AppKit reopened its windows makes the next launch wait on macOS's modal
        # "unexpectedly quit while reopening windows" alert, which stalls the main run loop; with this AppKit skips
        # window restoration and that alert.
        self._write_default("ApplePersistenceIgnoreState", "-bool", "YES")
        if site_engines:
            args = []
            for site, engine in site_engines.items():
                args += [site, engine]
            self._write_default("browser.settings.siteEngines", "-dict", *args)

    def engine_framework(self) -> Path:
        return self.app / "Contents" / "Frameworks" / CHROME_ENGINE_FRAMEWORK

    @staticmethod
    def _read_plist(path: Path) -> dict:
        with path.open("rb") as handle:
            return plistlib.load(handle)

    @staticmethod
    def _set_identity(path: Path, bundle_id: str, name: str | None) -> None:
        run(["/usr/bin/plutil", "-replace", "CFBundleIdentifier", "-string", bundle_id, str(path)])
        if name:
            run(["/usr/bin/plutil", "-replace", "CFBundleDisplayName", "-string", name, str(path)])

    def _write_default(self, key: str, *value: str) -> None:
        run(["/usr/bin/defaults", "write", COPY_BUNDLE_ID, key, *value])

    def _reset_defaults(self) -> None:
        run(["/usr/bin/defaults", "delete", COPY_BUNDLE_ID], check=False)

    # Running

    def launch(self) -> None:
        log_path = self.out_dir / "app.log"
        arguments = [
            f"--runtime-suffix={self.suffix}",
            f"--agent-socket={self.socket}",
            "--no-activate",
            f"--openarc-engine={self.engine}",
            "--use-mock-keychain",
            f"--load-extension={self.extension}",
        ]
        log(f"Starting the copy: {' '.join(arguments)}")
        self.started_at = time.time()
        # LaunchServices with -g starts the app in the background. Started directly,
        # macOS makes a new GUI process frontmost even though it never activates itself.
        # Apps it starts get launchd's environment, so no OPENARC_SYNC_BASE_URL reaches the copy.
        run(["/usr/bin/open", "-g", "-n", "-a", str(self.app), "--stdout", str(log_path), "--stderr", str(log_path),
             "--args", *arguments], timeout=60)
        executable = str(self.app / "Contents" / "MacOS" / "OpenArc")

        def main_pid():
            output = run(["/usr/bin/pgrep", "-f", f"^{re.escape(executable)}( |$)"], check=False).stdout.split()
            return int(output[0]) if output else None

        self._pid = wait_until(main_pid, 20, 0.2)
        if not self._pid:
            raise RuntimeError("the copy's main process did not start")

    @property
    def pid(self) -> int:
        return self._pid or -1

    def alive(self) -> bool:
        if not self._pid:
            return False
        try:
            os.kill(self._pid, 0)
        except ProcessLookupError:
            return False
        return run(["/bin/ps", "-o", "stat=", "-p", str(self._pid)], check=False).stdout.strip()[:1] not in ("Z", "")

    def cli(self, *args: str, timeout: float = 60) -> object:
        env = dict(os.environ, OPENARC_AGENT_SOCKET=self.socket)
        result = run([str(self.cli_path), "--json", *args], timeout=timeout, check=False, env=env)
        if result.returncode != 0:
            raise RuntimeError(f"openarc {args[0]}: {(result.stderr or result.stdout).strip()[:400]}")
        text = result.stdout.strip()
        try:
            return json.loads(text) if text else None
        except json.JSONDecodeError:
            return text

    def eval(self, script: str, tab: str | None = None, timeout: float = 60):
        args = ["eval", script] if tab is None else ["eval", "--tab", tab, script]
        result = self.cli(*args, timeout=timeout)
        return result.get("value") if isinstance(result, dict) else result

    def wait_ready(self, timeout: float = 90) -> dict:
        def ready():
            if not self.alive():
                raise RuntimeError("the copy exited; see app.log")
            if not os.path.exists(self.socket):
                return None
            try:
                status = self.cli("status", timeout=10)
            except RuntimeError:
                return None
            return status if isinstance(status, dict) and status.get("windows", 0) > 0 else None

        status = wait_until(ready, timeout, interval=0.5)
        if not status:
            raise RuntimeError(f"the agent socket did not answer within {timeout:.0f} s")
        return status

    def main_window(self, cua: Cua) -> dict | None:
        windows = [w for w in cua.windows(self.pid) if w.get("layer") == 0 and w["bounds"]["width"] > 400]
        return max(windows, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"], default=None)

    # Teardown

    def stop(self) -> None:
        # SIGTERM would show the quit alert; helpers outlive the main process for a moment.
        if self.alive():
            os.kill(self._pid, signal.SIGKILL)
        run(["/usr/bin/pkill", "-9", "-f", str(self.app)], check=False)
        wait_until(lambda: not run(["/usr/bin/pgrep", "-f", str(self.app)], check=False).stdout.strip(), 10, 0.3)

    def clean(self) -> None:
        for name in (f"CEF-{self.suffix}", f"Session-{self.suffix}"):
            shutil.rmtree(SUPPORT / name, ignore_errors=True)
        self._reset_defaults()
        run([LSREGISTER, "-u", str(self.app)], check=False)
        shutil.rmtree(self.app, ignore_errors=True)
        (self.work_dir / "entitlements.plist").unlink(missing_ok=True)
        Path(self.socket).unlink(missing_ok=True)

    def profile_dirs(self) -> list[Path]:
        root = SUPPORT / f"CEF-{self.suffix}"
        return [Path(p).parent for p in glob.glob(str(root / "**" / "History"), recursive=True)]


# MARK: - System state readers


def frontmost_pid() -> int | None:
    result = run(["/usr/bin/lsappinfo", "front"], check=False, timeout=5)
    asn = result.stdout.strip()
    if not asn:
        return None
    info = run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn], check=False, timeout=5).stdout
    match = re.search(r"=\s*(\d+)", info)
    return int(match.group(1)) if match else None


class FocusWatch:
    """Polls the frontmost app while the copy runs."""

    def __init__(self, pid_provider):
        self.pid_provider = pid_provider
        self.samples = 0
        self.hits: list[float] = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _loop(self) -> None:
        while not self.stop_event.is_set():
            front = frontmost_pid()
            self.samples += 1
            if front is not None and front == self.pid_provider():
                self.hits.append(time.time())
            self.stop_event.wait(0.5)

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=5)


def tcc_state(service: str, client: str) -> str:
    """allowed, denied, not determined, or unknown when the databases can't be read."""
    readable = False
    for database in (SYSTEM_TCC, USER_TCC):
        try:
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
            rows = connection.execute(
                "SELECT auth_value FROM access WHERE service = ? AND client = ?", (service, client),
            ).fetchall()
            connection.close()
            readable = True
        except sqlite3.Error:
            continue
        if rows:
            return {0: "denied", 2: "allowed", 3: "limited"}.get(rows[0][0], f"auth_value {rows[0][0]}")
    return "not determined" if readable else "unknown"


class BannerWatch:
    """Watches macOS's notification banners and prompts for ones that name the copy.

    NotificationCenter draws every banner in one window that is on screen only while
    a banner shows; its accessibility tree holds the banner's text."""

    def __init__(self, cua: Cua, out_dir: Path):
        self.cua = cua
        self.out_dir = out_dir
        self.seen: list[dict] = []
        self.samples = 0
        self.errors: list[str] = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> None:
        if self.cua.available:
            self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread.is_alive():
            self.thread.join(timeout=10)

    def since(self, moment: float) -> list[dict]:
        return [banner for banner in self.seen if banner["time"] >= moment]

    def _loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                self._sample()
            except Exception as error:  # noqa: BLE001 - keep watching
                self.errors.append(str(error)[:200])
            self.stop_event.wait(1)

    def _sample(self) -> None:
        self.samples += 1
        for pid in run(["/usr/bin/pgrep", "-x", "NotificationCenter"], check=False).stdout.split():
            for window in self.cua.windows(int(pid)):
                if not window.get("is_on_screen"):
                    continue
                state = self.cua.state(int(pid), window["window_id"], max_elements=300)
                rows = [text for _, text in tree_rows(state) if COPY_NAME in text]
                if not rows:
                    continue
                known = {row for banner in self.seen for row in banner["rows"]}
                if set(rows) <= known:
                    continue
                path = self.out_dir / f"notification-banner-{len(self.seen) + 1}.png"
                shot = self.cua.screenshot(int(pid), window["window_id"], path)
                self.seen.append({"time": time.time(), "rows": rows, "pid": int(pid),
                                  "window_id": window["window_id"], "screenshot": str(shot) if shot else None})



class LogWatch:
    """Streams the system log for notification permission requests by the copy.

    The process itself logs "Requesting authorization" whatever macOS already
    decided; usernoted logs "Sending request for permission" when it shows a prompt.
    Streaming catches messages that `log show` later no longer has."""

    MARKERS = ("Getting notification settings", "Requesting authorization", "Sending request for permission",
               "Authorization set for")
    PROMPTING = ("Requesting authorization", "Sending request for permission")

    def __init__(self, out_dir: Path):
        self.path = out_dir / "notification-log.txt"
        self.process: subprocess.Popen | None = None

    def start(self) -> None:
        predicate = (f'eventMessage CONTAINS "{COPY_BUNDLE_ID}" AND '
                     f'(subsystem == "com.apple.UserNotifications" OR process == "usernoted")')
        self.handle = self.path.open("w")
        self.process = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--predicate", predicate],
                                        stdout=self.handle, stderr=subprocess.DEVNULL)
        time.sleep(1)

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)
            self.handle.close()

    def requests(self, since: float = 0, until: float | None = None) -> list[dict]:
        """Permission requests and decisions as {time, process, message}."""
        found = []
        try:
            lines = self.path.read_text(errors="replace").splitlines()
        except OSError:
            return found
        for line in lines:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = entry.get("eventMessage", "")
            if not any(marker in message for marker in self.MARKERS):
                continue
            try:
                moment = dt.datetime.strptime(entry["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f").timestamp()
            except (KeyError, ValueError):
                moment = 0
            if moment < since or (until is not None and moment > until):
                continue
            process = Path(entry.get("processImagePath", "")).name
            found.append({"time": moment, "process": process, "message": message[:300]})
        return found


def new_crash_reports(since: float, app_path: Path) -> list[str]:
    # Any process of the copy counts, helpers too (a helper's report is named after the helper). An .ips report is
    # JSON with its slashes escaped, and macOS writes the home folder as /Users/USER with the folders below it
    # starred, so the bundle's name decides.
    found = []
    markers = (str(app_path), str(app_path.resolve()), f"/{app_path.name}/Contents/")
    for directory in CRASH_DIRS:
        for path in directory.glob("*"):
            try:
                if path.stat().st_mtime < since:
                    continue
                text = path.read_text(errors="replace")[:20000].replace("\\/", "/")
            except OSError:
                continue
            if any(marker in text for marker in markers):
                found.append(str(path))
    return found


# MARK: - The run


class SmokeTest:
    def __init__(self, options: argparse.Namespace):
        self.options = options
        self.out_dir = options.out
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.results: list[dict] = []
        self.cua = Cua(session=f"oa-smoke-{random_token()}")
        self.server = FixtureServer(FIXTURES)
        self.webkit_server = FixtureServer(FIXTURES)
        self.instance = Instance(options.app, self.out_dir, options.identity, FIXTURES / "extension", options.engine)
        self.tabs: dict[str, str] = {}
        self.focus = FocusWatch(lambda: self.instance.pid)
        self.banners = BannerWatch(self.cua, self.out_dir)
        self.system_log = LogWatch(self.out_dir)
        self.window: dict | None = None
        self.facts: dict = {}

    # Recording

    def check(self, name: str, function) -> None:
        gaps = {"chrome": CHROME_ENGINE_GAPS, "webkit": WEBKIT_ENGINE_GAPS,
                "ladybird": LADYBIRD_ENGINE_GAPS}.get(self.options.engine, {})
        if name in gaps:
            prefix = {"chrome": "not on the Chrome engine yet", "ladybird": "not on Ladybird"}.get(
                self.options.engine, "Chromium only")
            reason = f"{prefix}: {gaps[name]}"
            log(f"• {name}: SKIP, {reason}")
            self.results.append({"name": name, "status": "skip", "evidence": reason, "details": {}})
            return
        log(f"• {name} …")
        started = time.monotonic()
        entry: dict = {"name": name}
        try:
            outcome = function() or {}
            entry["status"] = outcome.pop("status", "pass")
            entry["evidence"] = outcome.pop("evidence", "")
            entry["details"] = outcome
        except CheckSkipped as skip:
            entry.update(status="skip", evidence=skip.reason, details=skip.details)
        except CheckFailed as failure:
            entry.update(status="fail", evidence=failure.evidence, details=failure.details)
        except Exception as error:  # noqa: BLE001 - a broken check is a failed check
            entry.update(status="fail", evidence=f"{type(error).__name__}: {error}", details={})
        entry["seconds"] = round(time.monotonic() - started, 1)
        self.results.append(entry)
        log(f"  {entry['status'].upper()}: {entry['evidence']}")

    def shot(self, name: str, window_id: int | None = None) -> str | None:
        """A picture of one of the copy's windows, taken without bringing it forward."""
        window_id = window_id or (self.window or {}).get("window_id")
        if not window_id:
            return None
        path = self.out_dir / f"{name}.png"
        run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window_id), str(path)], check=False, timeout=30)
        if not path.exists() and self.cua.available:
            self.cua.screenshot(self.instance.pid, window_id, path)
        return str(path) if path.exists() else None

    def copy_windows(self) -> dict[int, dict]:
        return {w["window_id"]: w for w in self.cua.windows(self.instance.pid)}

    def wait_new_window(self, before: set[int], timeout: float = 10) -> dict | None:
        def found():
            fresh = [w for wid, w in self.copy_windows().items() if wid not in before and w.get("is_on_screen")]
            return fresh[0] if fresh else None

        return wait_until(found, timeout, 0.5)

    def page_value(self, tab: str, key: str, timeout: float = 15, done=lambda v: v not in (None, "pending")):
        """window.smoke[key] on the permissions fixture, once it settles."""
        script = f"JSON.stringify((window.smoke || {{}})[{json.dumps(key)}] ?? null)"
        return wait_until(lambda: (lambda v: v if done(v) else None)(json.loads(self.instance.eval(script, tab))),
                          timeout, 0.5)

    def open_tab(self, key: str, url: str) -> str:
        result = self.instance.cli("open", url, timeout=60)
        tab = result["tab"]
        self.tabs[key] = tab
        return tab

    def select(self, tab: str) -> None:
        self.instance.cli("select", tab)
        time.sleep(0.5)

    # Flow

    def run(self) -> int:
        major = None if self.options.engine in ("webkit", "ladybird") else (self.options.expect_chrome_major
                                                              or expected_chrome_major())
        self.facts.update(app=str(self.options.app), engine=self.options.engine, expected_chrome_major=major,
                          bundle_id=COPY_BUNDLE_ID,
                          fixture_port=self.server.port, webkit_port=self.webkit_server.port,
                          started=dt.datetime.now().isoformat(timespec="seconds"))
        screen_capture_before = tcc_state("kTCCServiceScreenCapture", COPY_BUNDLE_ID)
        self.facts.update(screen_recording_state=screen_capture_before)
        try:
            webkit_site = f"http://127.0.0.1:{self.webkit_server.port}"
            self.instance.prepare({webkit_site: "webkit"})
            self.banners.start()
            self.system_log.start()
            self.focus.start()
            self.instance.launch()
            status = self.instance.wait_ready()
            self.facts["launch_seconds"] = round(time.time() - self.instance.started_at, 1)
            self.facts["initial_status"] = status
            if self.cua.available:
                self.window = wait_until(lambda: self.instance.main_window(self.cua), 20, 0.5)
        except Exception as error:  # noqa: BLE001
            log(f"Setup failed: {error}")
            self.results.append({"name": "setup", "status": "fail", "evidence": str(error), "details": {}})
            self.finish()
            return 2

        self.check("chromium-engine", self.check_chromium_engine)
        self.check("sandbox", self.check_sandbox)
        self.check("no-notification-request-at-launch", self.check_notifications_at_launch)
        self.check("engine-version", lambda: self.check_engine(major))
        self.check("page-load-js-navigation", self.check_navigation)
        self.check("webassembly", self.check_webassembly)
        self.check("proprietary-codecs", self.check_codecs)
        self.check("extension-sees-tabs", self.check_extension_tabs)
        self.check("passkeys", self.check_passkeys)
        self.check("media-devices", self.check_media_devices)
        self.check("history", self.check_history)
        self.check("webkit-engine", self.check_webkit)
        if self.options.no_gui:
            for name in ("print-preview", "screen-share-picker", "extension-popup",
                         "notification-after-site-permission"):
                self.results.append({"name": name, "status": "skip", "evidence": "--no-gui", "details": {}})
        else:
            self.check("print-preview", self.check_print_preview)
            self.check("screen-share-picker", lambda: self.check_screen_share(screen_capture_before))
            self.check("extension-popup", self.check_extension_popup)
            self.check("notification-after-site-permission", self.check_notification_permission)
        self.check("translate-in-place", self.check_translate)
        self.qualify_launch_notification_check()
        self.check("background-launch", self.check_background)
        self.check("stability", self.check_stability)
        return self.finish()

    def finish(self) -> int:
        self.focus.stop()
        self.banners.stop()
        self.system_log.stop()
        if self.options.keep:
            log(f"--keep: the copy keeps running (pid {self.instance.pid}, socket {self.instance.socket}).")
        else:
            self.instance.stop()
            self.instance.clean()
        self.cua.end()
        self.server.close()
        self.webkit_server.close()
        failed = [r for r in self.results if r["status"] == "fail"]
        summary = {
            "ok": not failed,
            "facts": self.facts,
            "counts": {s: sum(r["status"] == s for r in self.results) for s in ("pass", "warn", "fail", "skip")},
            "checks": self.results,
            "report_dir": str(self.out_dir),
        }
        (self.out_dir / "report.json").write_text(json.dumps(summary, indent=2, default=str))
        self.print_report(summary)
        if any(r["name"] == "setup" for r in failed):
            return 2
        return 1 if failed else 0

    def print_report(self, summary: dict) -> None:
        marks = {"pass": "PASS", "warn": "WARN", "fail": "FAIL", "skip": "SKIP"}
        print(f"OpenArc engine smoke test: {self.options.app}")
        print(f"Engine {self.options.engine}, expected Chromium {self.facts.get('expected_chrome_major')}, "
              f"copy {COPY_BUNDLE_ID}, "
              f"report {self.out_dir}")
        print()
        for result in self.results:
            print(f"[{marks.get(result['status'], result['status'])}] {result['name']} ({result.get('seconds', 0)} s)")
            print(f"       {result['evidence']}")
            for shot in result.get("details", {}).get("screenshots", []) or []:
                print(f"       screenshot: {shot}")
        counts = summary["counts"]
        print()
        print(f"{counts['pass']} passed, {counts['warn']} passed with notes, {counts['fail']} failed, "
              f"{counts['skip']} skipped")
        print()
        print("JSON summary:")
        print(json.dumps({"ok": summary["ok"], "counts": counts, "report": str(self.out_dir / "report.json"),
                          "checks": {r["name"]: r["status"] for r in self.results}}, indent=2))

    # MARK: Checks

    def check_notifications_at_launch(self) -> dict:
        tab = self.open_tab("start", self.server.url("index.html"))
        permission = self.instance.eval(
            "typeof Notification === 'function' && Notification.permission ? Notification.permission"
            " : 'unsupported'", tab)
        query = self.instance.eval(
            "navigator.permissions ? navigator.permissions.query({name: 'notifications'}).then(s => s.state)"
            " : 'unsupported'", tab)
        # The prompt came about four seconds after launch when the engine asked at startup.
        remaining = self.instance.started_at + 10 - time.time()
        if remaining > 0:
            time.sleep(remaining)
        banners = self.banners.since(self.instance.started_at)
        requests = [r for r in self.system_log.requests(since=self.instance.started_at - 1)
                    if any(marker in r["message"] for marker in LogWatch.PROMPTING)]
        details = {"permission": permission, "permissions_query": query, "banners": banners,
                   "system_log_requests": requests,
                   "banner_samples": self.banners.samples, "banner_errors": self.banners.errors[:3],
                   "screenshots": [b["screenshot"] for b in banners if b["screenshot"]],
                   "method": f"Notification.permission and permissions.query in a page; the system log streamed "
                             f"from before launch for 'Requesting authorization' (logged by the asking process "
                             f"whatever macOS decided before) and usernoted's 'Sending request for permission' "
                             f"for {COPY_BUNDLE_ID} and its helpers; for the first 10 s, macOS's NotificationCenter "
                             f"window is read every second (cua-driver) for prompts naming {COPY_NAME!r}"}
        problems = []
        # Ladybird has neither notifications nor the Permissions API; the system log and the banners still tell.
        unsupported = "unsupported" if self.options.engine == "ladybird" else None
        if permission not in ("default", unsupported):
            problems.append(f"Notification.permission is {permission!r}")
        if query not in ("prompt", unsupported):
            problems.append(f"permissions.query is {query!r}")
        if requests:
            problems.append(f"the copy asked macOS for notification permission at launch: "
                            f"{requests[0]['process']}: {requests[0]['message'][:160]}")
        if banners:
            problems.append("macOS showed a notification prompt for the copy at launch: "
                            + " | ".join(banners[0]["rows"])[:300])
        if problems:
            raise CheckFailed("; ".join(problems), details)
        watched = (f"no macOS prompt naming {COPY_NAME!r} in {self.banners.samples} reads of NotificationCenter"
                   if self.banners.samples else "macOS banners not watched (no cua-driver)")
        return {"evidence": f"Notification.permission={permission}, permissions.query={query}; no permission "
                            f"request from the copy in the system log during the first 10 s; {watched}",
                **details}

    def check_chromium_engine(self) -> dict:
        """Pages run where --engine says: renderers from the Chrome engine's framework, or CEF's helpers."""
        frameworks = self.instance.app / "Contents" / "Frameworks"
        if self.options.engine == "webkit":
            return self.check_no_chromium(frameworks)
        if self.options.engine == "ladybird":
            return self.check_ladybird_processes(frameworks)
        engine_helpers = str(self.instance.engine_framework()) + "/"

        def renderers():
            lines = run(["/usr/bin/pgrep", "-fl", "--", "--type=renderer"], check=False).stdout.splitlines()
            ours = [line for line in lines if str(frameworks) in line]
            return ours or None

        found = wait_until(renderers, 20, 0.5) or []
        on_chrome = [line for line in found if engine_helpers in line]
        details = {"renderers": found, "method": "renderer processes of the copy by executable path"}
        if self.options.engine == "chrome":
            if not self.instance.engine_framework().exists():
                raise CheckFailed(f"the app has no {CHROME_ENGINE_FRAMEWORK}", details)
            if not on_chrome or len(on_chrome) != len(found):
                raise CheckFailed(f"{len(on_chrome)} of {len(found)} renderers run from the Chrome engine's "
                                  "framework", details)
            return {"evidence": f"{len(found)} renderers run from {CHROME_ENGINE_FRAMEWORK}", **details}
        if not found or on_chrome:
            raise CheckFailed(f"{len(found)} renderers, {len(on_chrome)} from the Chrome engine's framework",
                              details)
        return {"evidence": f"{len(found)} renderers run from CEF's helpers", **details}

    def check_sandbox(self) -> dict:
        """Chromium's processes run inside the macOS sandbox, so a page that breaks the engine stays locked in."""
        frameworks = str(self.instance.app / "Contents" / "Frameworks") + "/"
        sandbox_check = ctypes.CDLL("/usr/lib/libSystem.B.dylib").sandbox_check
        sandbox_check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        sandbox_check.restype = ctypes.c_int
        if self.options.engine == "ladybird":
            return self.check_ladybird_sandbox(sandbox_check)
        processes, unsandboxed = [], []
        for line in run(["/bin/ps", "-axww", "-o", "pid=,command="], check=False).stdout.splitlines():
            pid, _, command = line.strip().partition(" ")
            kind = re.search(r"--type=([a-z-]+)", command)
            if frameworks not in command or not kind or kind.group(1) not in ("renderer", "gpu-process", "utility"):
                continue
            service = re.search(r"--utility-sub-type=(\S+)", command)
            name = kind.group(1) + (f" {service.group(1)}" if service else "")
            if service and service.group(1) in UNSANDBOXED_SERVICES:
                continue
            processes.append(name)
            if "--no-sandbox" in command or sandbox_check(int(pid), None, 0) != 1:
                unsandboxed.append(f"{pid} {name}")
        details = {"processes": sorted(processes), "unsandboxed": unsandboxed,
                   "skipped_services": sorted(UNSANDBOXED_SERVICES),
                   "method": "sandbox_check() on every renderer, GPU and utility process of the copy, and no "
                             "--no-sandbox on their command lines"}
        if not any(name == "renderer" for name in processes):
            raise CheckFailed("no renderer process of the copy was found", details)
        if unsandboxed:
            raise CheckFailed(f"{len(unsandboxed)} of {len(processes)} processes run without the sandbox", details)
        return {"evidence": f"all {len(processes)} renderer, GPU and utility processes run in the sandbox", **details}

    def check_no_chromium(self, frameworks: Path) -> dict:
        """On WebKit, no Chromium loads: no helper process from the bundle and neither framework in the app."""
        time.sleep(2)
        helpers = [line for line in run(["/usr/bin/pgrep", "-fl", "--", str(frameworks)], check=False)
                   .stdout.splitlines() if line.strip()]
        mapped = run(["/usr/sbin/lsof", "-p", str(self.instance.pid), "-Fn"], check=False, timeout=30).stdout
        loaded = sorted({name for name in ("Chromium Embedded Framework", "OpenArc Framework")
                         if f"/{name}.framework/" in mapped})
        details = {"helper_processes": helpers, "loaded_frameworks": loaded,
                   "method": "processes started from the copy's Contents/Frameworks, and the main process's "
                             "open files (lsof) for CEF's and the Chrome engine's frameworks"}
        if helpers or loaded:
            raise CheckFailed(f"Chromium runs on WebKit: {len(helpers)} helper process(es), frameworks loaded: "
                              f"{loaded or 'none'}", details)
        return {"evidence": "no helper process from the bundle; neither CEF nor the Chrome engine is loaded",
                **details}

    def check_ladybird_processes(self, frameworks: Path) -> dict:
        """On Ladybird, pages run in WebContent helpers from Ladybird's framework, and no Chromium loads."""
        helpers_dir = str(frameworks / LADYBIRD_ENGINE_FRAMEWORK) + "/"

        def web_content():
            lines = run(["/usr/bin/pgrep", "-fl", "--", "WebContent"], check=False).stdout.splitlines()
            ours = [line for line in lines if helpers_dir in line]
            return ours or None

        found = wait_until(web_content, 20, 0.5) or []
        chromium = [line for line in run(["/usr/bin/pgrep", "-fl", "--", "--type=renderer"], check=False)
                    .stdout.splitlines() if str(frameworks) in line]
        mapped = run(["/usr/sbin/lsof", "-p", str(self.instance.pid), "-Fn"], check=False, timeout=30).stdout
        loaded = sorted({name for name in ("Chromium Embedded Framework", "OpenArc Framework", "OpenArc Ladybird")
                         if f"/{name}.framework/" in mapped})
        details = {"web_content": found, "chromium_renderers": chromium, "loaded_frameworks": loaded,
                   "method": "WebContent processes started from the copy's Ladybird framework, Chromium renderers "
                             "from the bundle, and the main process's open files (lsof)"}
        if not found:
            raise CheckFailed("no WebContent process from the Ladybird framework", details)
        if chromium or loaded != ["OpenArc Ladybird"]:
            raise CheckFailed(f"Chromium runs on Ladybird: {len(chromium)} renderer(s), frameworks loaded: {loaded}",
                              details)
        return {"evidence": f"{len(found)} WebContent process(es) from {LADYBIRD_ENGINE_FRAMEWORK}; no Chromium "
                            "renderer, and only Ladybird's framework is loaded", **details}

    def check_ladybird_sandbox(self, sandbox_check) -> dict:
        """Ladybird's helpers that handle pages, images, requests and drawing run inside the macOS sandbox."""
        helpers = str(self.instance.app / "Contents" / "Frameworks" / LADYBIRD_ENGINE_FRAMEWORK) + "/"
        sandboxed_kinds = ("WebContent", "WebWorker", "ImageDecoder", "RequestServer", "Compositor", "MediaServer",
                           "WasmCompiler")
        processes, unsandboxed = [], []
        for line in run(["/bin/ps", "-axww", "-o", "pid=,command="], check=False).stdout.splitlines():
            pid, _, command = line.strip().partition(" ")
            if helpers not in command:
                continue
            name = command.split("/Helpers/", 1)[-1].split(" ", 1)[0]
            if name not in sandboxed_kinds:
                continue
            processes.append(name)
            if sandbox_check(int(pid), None, 0) != 1:
                unsandboxed.append(f"{pid} {name}")
        details = {"processes": sorted(processes), "unsandboxed": unsandboxed,
                   "method": "sandbox_check() on every page, worker, image, request, media and drawing helper of "
                             "the copy's Ladybird framework"}
        if "WebContent" not in processes:
            raise CheckFailed("no WebContent process of the copy was found", details)
        if unsandboxed:
            raise CheckFailed(f"{len(unsandboxed)} of {len(processes)} Ladybird helpers run without a sandbox",
                              details)
        return {"evidence": f"all {len(processes)} Ladybird helpers ({', '.join(sorted(set(processes)))}) run in "
                            "the sandbox", **details}

    def check_ladybird_version(self) -> dict:
        tab = self.tabs["start"]
        user_agent = self.instance.eval("navigator.userAgent", tab)
        details = {"userAgent": user_agent}
        if "Ladybird/" not in (user_agent or ""):
            raise CheckFailed(f"the user agent is not Ladybird's: {user_agent!r}", details)
        return {"evidence": f"Ladybird's user agent: {user_agent}", **details}

    def check_webkit_version(self) -> dict:
        tab = self.tabs["start"]
        user_agent = self.instance.eval("navigator.userAgent", tab)
        details = {"userAgent": user_agent}
        if "Chrome/" in (user_agent or "") or not re.search(r"AppleWebKit/[\d.]+.*Version/[\d.]+ Safari/",
                                                            user_agent or ""):
            raise CheckFailed(f"the user agent is not Safari's: {user_agent!r}", details)
        return {"evidence": f"Safari's user agent, no Chrome token: {user_agent}", **details}

    def check_engine(self, major: int | None) -> dict:
        if self.options.engine == "webkit":
            return self.check_webkit_version()
        if self.options.engine == "ladybird":
            return self.check_ladybird_version()
        tab = self.tabs["start"]
        user_agent = self.instance.eval("navigator.userAgent", tab)
        brands = self.instance.eval(
            "navigator.userAgentData ? navigator.userAgentData.getHighEntropyValues(['fullVersionList'])"
            ".then(v => v.fullVersionList) : null", tab)
        ua_major = re.search(r"Chrome/(\d+)", user_agent or "")
        chromium = next((b for b in brands or [] if b.get("brand") == "Chromium"), None)
        details = {"userAgent": user_agent, "fullVersionList": brands}
        cef_plist = self.instance.app / "Contents" / "Frameworks" / "Chromium Embedded Framework.framework" / \
            "Resources" / "Info.plist"
        if cef_plist.exists():
            details["cef_framework_version"] = Instance._read_plist(cef_plist).get("CFBundleShortVersionString")
        if major is None:
            raise CheckFailed(f"can't read CHROME_VERSION_MAJOR from {CEF_VERSION_HEADER}", details)
        got = {int(ua_major.group(1)) if ua_major else None,
               int(chromium["version"].split(".")[0]) if chromium else None}
        if got != {major}:
            raise CheckFailed(f"expected Chromium {major}; userAgent Chrome/{ua_major and ua_major.group(1)}, "
                              f"userAgentData Chromium {chromium and chromium['version']}", details)
        return {"evidence": f"Chromium {chromium['version']} (userAgent Chrome/{major}), expected {major}",
                **details}

    def check_navigation(self) -> dict:
        tab = self.tabs["start"]
        steps = {}
        steps["script"] = self.instance.eval("document.getElementById('sum').textContent", tab)
        steps["navigate"] = self.instance.cli("navigate", "--tab", tab, self.server.url("two.html"))
        steps["navigated_title"] = self.instance.eval("document.title", tab)
        steps["back"] = self.instance.cli("back", "--tab", tab)
        steps["back_title"] = self.instance.eval("document.title", tab)
        steps["forward"] = self.instance.cli("forward", "--tab", tab)
        steps["forward_title"] = self.instance.eval("document.title", tab)
        steps["history_length"] = self.instance.eval("history.length", tab)
        expected = {"script": "42", "navigated_title": "Smoke Two", "back_title": "Smoke One",
                    "forward_title": "Smoke Two"}
        wrong = {k: steps[k] for k, v in expected.items() if steps[k] != v}
        if wrong:
            raise CheckFailed(f"unexpected values: {wrong}", {"steps": steps})
        return {"evidence": "script wrote 42; navigate → 'Smoke Two'; back → 'Smoke One'; forward → 'Smoke Two'; "
                            f"history.length {steps['history_length']}", "steps": steps}

    def check_webassembly(self) -> dict:
        """A page compiles and runs a WebAssembly module (on Ladybird, through WasmCompiler's own compiler)."""
        tab = self.open_tab("wasm", self.server.url("media.html"))
        # (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
        module = [0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 7, 7, 1, 3, 97, 100, 100,
                  0, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 106, 11]
        since = time.time()
        value = self.instance.eval(
            f"WebAssembly.instantiate(new Uint8Array({module})).then(m => m.instance.exports.add(40, 2))", tab)
        time.sleep(2)
        reports = new_crash_reports(since, self.instance.app)
        details = {"value": value, "crash_reports": reports,
                   "method": "WebAssembly.instantiate of a module that adds two numbers, then crash reports of the "
                             "copy's processes written meanwhile"}
        if value != 42 or reports:
            raise CheckFailed(f"add(40, 2) returned {value!r}; crash reports: {reports or 'none'}", details)
        return {"evidence": "add(40, 2) = 42 in a compiled module, with no crash report", **details}

    def check_codecs(self) -> dict:
        tab = self.open_tab("media", self.server.url("media.html"))
        support = self.instance.eval(
            "({h264: document.createElement('video').canPlayType('video/mp4; codecs=\"avc1.42E01E\"'),"
            " aac: document.createElement('audio').canPlayType('audio/mp4; codecs=\"mp4a.40.2\"'),"
            " mseH264: window.MediaSource ? MediaSource.isTypeSupported('video/mp4; codecs=\"avc1.42E01E\"') : null,"
            " mseAAC: window.MediaSource ? MediaSource.isTypeSupported('audio/mp4; codecs=\"mp4a.40.2\"') : null})",
            tab)
        playback = self.instance.eval(
            "(async () => { const v = document.getElementById('video');"
            " const start = v.currentTime; let playError = null;"
            " try { await v.play(); } catch (e) { playError = String(e); }"
            " await new Promise(r => setTimeout(r, 1500));"
            " return {start, currentTime: v.currentTime, paused: v.paused, readyState: v.readyState,"
            " videoWidth: v.videoWidth, videoHeight: v.videoHeight,"
            " error: v.error ? v.error.code + ' ' + v.error.message : null, playError,"
            " decoded: v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().totalVideoFrames : null}; })()",
            tab)
        # A playing video moves to Picture in Picture when its tab is left: stop it first.
        self.instance.eval("document.getElementById('video').pause(); true", tab)
        self.instance.cli("close", tab)
        details = {"canPlayType": support, "playback": playback, "fixture": "h264-aac.mp4 (H.264 Constrained "
                   "Baseline + AAC LC, generated with ffmpeg's testsrc and sine sources)"}
        problems = []
        if support.get("h264") != "probably":
            problems.append(f"H.264 canPlayType {support.get('h264')!r}")
        if support.get("aac") != "probably":
            problems.append(f"AAC canPlayType {support.get('aac')!r}")
        if not playback or playback.get("error") or playback.get("playError"):
            problems.append(f"playback error {playback}")
        elif playback["currentTime"] <= playback["start"] + 0.3:
            problems.append(f"currentTime did not advance ({playback['start']} → {playback['currentTime']})")
        elif playback["videoWidth"] != 96:
            problems.append(f"videoWidth {playback['videoWidth']}, expected 96")
        if problems:
            raise CheckFailed("; ".join(problems), details)
        return {"evidence": f"canPlayType H.264 and AAC 'probably'; the fixture played "
                            f"{playback['start']:.2f} → {playback['currentTime']:.2f} s at "
                            f"{playback['videoWidth']}x{playback['videoHeight']}, "
                            f"{playback['decoded']} frames decoded", **details}

    def extension_answer(self, tab: str, timeout: float = 15) -> dict | None:
        """Asks the test extension again and waits for its fresh answer."""
        self.instance.eval("document.documentElement.removeAttribute('data-smoke-tabs');"
                           " document.dispatchEvent(new Event('smoke-tabs-refresh')); true", tab)

        def answer():
            raw = self.instance.eval("document.documentElement.getAttribute('data-smoke-tabs')", tab)
            return json.loads(raw) if raw else None

        return wait_until(answer, timeout, 0.5)

    def check_extension_tabs(self) -> dict:
        tab = self.tabs["start"]
        # A tab that was never shown must be visible to extensions too.
        self.open_tab("extra", self.server.url("two.html?extra"))
        self.select(tab)
        answer = self.extension_answer(tab)
        tabs = self.instance.cli("tabs")
        details = {"extension_answer": answer, "openarc_tabs": tabs,
                   "method": "--load-extension with script/cef_smoke_test/fixtures/extension; its content script "
                             "asks the service worker for chrome.tabs.query({}) and writes the answer into the page"}
        if answer is None:
            has_runtime = self.instance.eval("typeof chrome !== 'undefined' && !!chrome.runtime", tab)
            raise CheckFailed(f"the test extension's content script never answered (chrome.runtime in page: "
                              f"{has_runtime}); the extension may not have loaded", details)
        if "error" in answer:
            raise CheckFailed(f"chrome.tabs.query failed: {answer['error']}", details)
        expected_urls = sorted(t["url"] for t in tabs)
        seen_urls = sorted(answer.get("urls", []))
        details["expected_urls"] = expected_urls
        fixtures = {url for url in expected_urls if url.startswith(f"http://127.0.0.1:{self.server.port}/")}
        if answer["count"] != len(tabs):
            raise CheckFailed(f"chrome.tabs.query saw {answer['count']} tab(s), openarc tabs lists {len(tabs)}",
                              details)
        if not fixtures <= set(seen_urls):
            raise CheckFailed(f"chrome.tabs.query missed {sorted(fixtures - set(seen_urls))}", details)
        return {"evidence": f"chrome.tabs.query({{}}) returned {answer['count']} tab(s), as many as openarc tabs "
                            f"lists, including the {len(fixtures)} fixture tabs, one never shown", **details}

    def check_passkeys(self) -> dict:
        tab = self.tabs["start"]
        values = self.instance.eval(
            "(async () => { const out = {hasPublicKeyCredential: typeof PublicKeyCredential === 'function'};"
            " try { out.uvpaa = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(); }"
            " catch (e) { out.uvpaaError = String(e); }"
            " try { out.capabilities = await PublicKeyCredential.getClientCapabilities(); }"
            " catch (e) { out.capabilitiesError = String(e); }"
            " return out; })()", tab)
        if not values.get("hasPublicKeyCredential") or "uvpaaError" in values or "capabilitiesError" in values:
            raise CheckFailed(f"WebAuthn calls failed: {values}", values)
        note = ("" if values["uvpaa"] else
                "; false is expected here: the copy is re-signed without the webauthn keychain group")
        return {"status": "pass" if values["uvpaa"] else "warn",
                "evidence": f"isUserVerifyingPlatformAuthenticatorAvailable() → {values['uvpaa']}; "
                            f"getClientCapabilities() returned {len(values['capabilities'] or {})} keys{note}",
                **values}

    def check_media_devices(self) -> dict:
        tab = self.tabs["start"]
        values = self.instance.eval(
            "(async () => ({mediaDevices: !!navigator.mediaDevices,"
            " getDisplayMedia: typeof navigator.mediaDevices?.getDisplayMedia,"
            " getUserMedia: typeof navigator.mediaDevices?.getUserMedia,"
            " devices: (await navigator.mediaDevices.enumerateDevices()).map(d => d.kind)}))()", tab)
        if not values.get("mediaDevices") or values.get("getDisplayMedia") != "function":
            raise CheckFailed(f"navigator.mediaDevices is incomplete: {values}", values)
        return {"evidence": f"navigator.mediaDevices present; getDisplayMedia is a function; enumerateDevices "
                            f"listed {len(values['devices'])} device(s)", **values}

    def check_history(self) -> dict:
        wanted = [self.server.url("index.html"), self.server.url("two.html")]

        def visited():
            found = {}
            for profile in self.instance.profile_dirs():
                with tempfile.TemporaryDirectory() as scratch:
                    copy = Path(scratch) / "History"
                    try:
                        shutil.copy(profile / "History", copy)
                        connection = sqlite3.connect(f"file:{copy}?mode=ro", uri=True)
                        rows = connection.execute(
                            "SELECT url, title, visit_count FROM urls WHERE url LIKE ?",
                            (f"http://127.0.0.1:{self.server.port}/%",)).fetchall()
                        connection.close()
                    except (OSError, sqlite3.Error):
                        continue
                for url, title, count in rows:
                    found[url] = {"title": title, "visit_count": count, "profile": profile.name}
            return found if all(url in found for url in wanted) else None

        # Chromium writes history in batches, about every ten seconds.
        found = wait_until(visited, 30, 2)
        details = {"method": "reads the History database of the copy's CEF profile (what OpenArc's history "
                             "and command bar search read); the CLI has no history command", "rows": found}
        if not found:
            raise CheckFailed(f"{wanted} did not reach the History database within 30 s", details)
        return {"evidence": f"{len(found)} fixture URL(s) in History, including index.html and two.html", **details}

    def check_webkit(self) -> dict:
        url = f"http://127.0.0.1:{self.webkit_server.port}/webkit.html"
        chromium_url = self.server.url("webkit.html")
        details = {"method": f"the copy's defaults route {url.rsplit('/', 1)[0]} to WebKit "
                             "(browser.settings.siteEngines, the rule Settings writes); the fixture's script puts "
                             "the engine it sees into the title, which `openarc tabs` lists"}
        tab = self.open_tab("webkit", url)
        control = self.open_tab("webkit-control", chromium_url)

        def titles():
            listed = {t["id"]: t["title"] for t in self.instance.cli("tabs")}
            pair = (listed.get(tab), listed.get(control))
            return pair if all(title and title.startswith("Engine ") and title != "Engine pending"
                               for title in pair) else None

        pair = wait_until(titles, 15, 0.5)
        details["titles"] = {"webkit_site": pair and pair[0], "chromium_site": pair and pair[1]}
        self.instance.cli("close", tab)
        self.instance.cli("close", control)
        if not pair:
            raise CheckFailed("the fixture's script did not set the titles within 15 s", details)
        if self.options.engine == "ladybird":
            # Ladybird's user agent names no engine the fixture knows, or Chrome for compatibility.
            if not pair or pair[0] != "Engine webkit 42" or pair[1] not in ("Engine other 42", "Engine chromium 42"):
                raise CheckFailed(f"titles {pair}, expected 'Engine webkit 42' and Ladybird's for the other site",
                                  details)
            return {"evidence": f"the WebKit-routed site's script reported 'Engine webkit 42'; the same page on "
                                f"Ladybird reported {pair[1]!r}", **details}
        if self.options.engine == "webkit":
            if pair != ("Engine webkit 42", "Engine webkit 42"):
                raise CheckFailed(f"titles {pair}, expected 'Engine webkit 42' for both sites", details)
            return {"evidence": "both the WebKit-routed site and the other one reported 'Engine webkit 42'",
                    **details}
        if pair != ("Engine webkit 42", "Engine chromium 42"):
            raise CheckFailed(f"titles {pair}, expected ('Engine webkit 42', 'Engine chromium 42')", details)
        return {"evidence": "the WebKit-routed site's script reported 'Engine webkit 42'; the same page on "
                            "another port reported 'Engine chromium 42'", **details}

    # MARK: Window checks (cua-driver)

    def require_window(self) -> dict:
        if not self.cua.available:
            raise CheckSkipped("cua-driver is not installed, so windows can't be read in the background")
        if not self.window:
            raise CheckFailed("no browser window of the copy was found through cua-driver list_windows")
        return self.window

    def permissions_tab(self) -> str:
        if "permissions" not in self.tabs:
            self.open_tab("permissions", self.server.url("permissions.html"))
        tab = self.tabs["permissions"]
        self.select(tab)
        return tab

    def check_print_preview(self) -> dict:
        window = self.require_window()
        tab = self.permissions_tab()
        before = set(self.copy_windows())
        self.instance.cli("click", "--tab", tab, "#print")
        preview = self.wait_new_window(before, 15)
        details = {"method": "clicks the fixture's Print button (window.print()); the engine's print preview "
                             "opens as a window of its own over the browser window; Escape sent to it in the "
                             "background (cua-driver press_key) cancels it"}
        if not preview:
            details["screenshots"] = [self.shot("print-preview-missing", window["window_id"])]
            raise CheckFailed("no print preview window appeared within 15 s", details)
        state = self.cua.state(self.instance.pid, preview["window_id"], max_elements=5)
        title = (find_row(state, r"AXWindow") or ("", ""))[1]
        details.update(window=preview, ax_window=title,
                       screenshots=[self.shot("print-preview", preview["window_id"])])
        inside = (window["bounds"]["x"] <= preview["bounds"]["x"]
                  and preview["bounds"]["x"] + preview["bounds"]["width"]
                  <= window["bounds"]["x"] + window["bounds"]["width"])
        self.cua.call("press_key", {"pid": self.instance.pid, "window_id": preview["window_id"], "key": "escape"})
        closed = wait_until(lambda: preview["window_id"] not in self.copy_windows(), 10, 0.5)
        responsive = self.instance.eval("6 * 7", tab)
        details.update(closed=bool(closed), page_after=responsive)
        if '"Print"' not in title:
            raise CheckFailed(f"a window appeared but its title is {title!r}, not Print", details)
        if not closed:
            raise CheckFailed("the print preview did not close on Escape", details)
        if responsive != 42:
            raise CheckFailed(f"the page did not answer after the preview closed ({responsive!r})", details)
        return {"evidence": f"a {preview['bounds']['width']:.0f}x{preview['bounds']['height']:.0f} 'Print' window "
                            f"opened {'over' if inside else 'beside'} the browser window; Escape closed it and the "
                            f"page still runs scripts", **details}

    def check_screen_share(self, state: str) -> dict:
        window = self.require_window()
        details = {"screen_recording": state,
                   "method": "clicks the fixture's Share button (getDisplayMedia needs a user gesture); OpenArc's "
                             "picker is a sheet on the browser window, read and pressed through its "
                             "accessibility ids browser.screen-share.share and .cancel"}
        if state in ("not determined", "unknown") and not self.options.allow_system_prompts:
            raise CheckSkipped(
                f"Screen Recording for {COPY_BUNDLE_ID} is {state}: opening the picker makes macOS ask, and that "
                f"prompt is a person's to answer. Allow or deny it once (rerun with --allow-system-prompts and "
                f"answer the prompt), and later runs check the picker without prompts", details)
        tab = self.permissions_tab()
        self.instance.cli("click", "--tab", tab, "#share")

        def sheet():
            current = self.cua.state(self.instance.pid, window["window_id"], query="browser.screen-share",
                                     max_elements=3000)
            share = find_row(current, r"browser\.screen-share\.share")
            cancel = find_row(current, r"browser\.screen-share\.cancel")
            return (current, share, cancel) if share and cancel else None

        found = wait_until(sheet, 15, 1)
        if not found:
            details["screenshots"] = [self.shot("screen-share-missing", window["window_id"])]
            raise CheckFailed("the screen-share picker did not appear within 15 s", details)
        time.sleep(2)  # the sources and their pictures load after the sheet shows
        current = self.cua.state(self.instance.pid, window["window_id"], max_elements=3000)
        rows = [text for _, text in tree_rows(current)]
        start = next((i for i, text in enumerate(rows) if "screen-share" in text.lower() or "share" in text.lower()),
                     0)
        details["picker_rows"] = rows[max(0, start - 40):start + 40]
        details["screenshots"] = [self.shot("screen-share-picker", window["window_id"])]
        if state == "allowed":
            share = find_row(current, r"browser\.screen-share\.share")
            self.cua.press(self.instance.pid, window["window_id"], share[0])
            result = self.page_value(tab, "share", 20)
            details["result"] = result
            if not result or not result.get("ok"):
                raise CheckFailed(f"sharing the first source failed: {result}", details)
            return {"evidence": f"the picker listed sources; sharing the first gave a "
                                f"{result.get('surface')} track ({result.get('label')!r}), stopped at once",
                    **details}
        cancel = find_row(current, r"browser\.screen-share\.cancel")
        self.cua.press(self.instance.pid, window["window_id"], cancel[0])
        result = self.page_value(tab, "share", 15)
        details["result"] = result
        if not result or result.get("ok") or result.get("name") != "NotAllowedError":
            raise CheckFailed(f"Cancel did not reject getDisplayMedia with NotAllowedError: {result}", details)
        return {"status": "warn",
                "evidence": f"the picker sheet opened (Screen Recording for the copy: {state}, so it offers the "
                            f"main screen only); Cancel rejected getDisplayMedia with NotAllowedError. Picking a "
                            f"source needs Screen Recording allowed for {COPY_BUNDLE_ID}", **details}

    def check_extension_popup(self) -> dict:
        window = self.require_window()
        tab = self.tabs["start"]
        self.select(tab)
        title = self.instance.eval("document.title", tab)
        before = set(self.copy_windows())
        extension_name = json.loads((FIXTURES / "extension" / "manifest.json").read_text())["name"]
        result = self.cua.call("invoke_menu", {"pid": self.instance.pid, "path": ["Extensions", extension_name]})
        popup = self.wait_new_window(before, 10)
        details = {"menu": result.get("summary"),
                   "method": f"Extensions > {extension_name} pressed through accessibility in the background "
                             f"(cua-driver invoke_menu); the popup page sends its chrome.tabs.query({{active: true, "
                             f"currentWindow: true}}) result to the service worker, which the content script "
                             f"puts into the page for `openarc eval`"}
        if not popup:
            details["screenshots"] = [self.shot("extension-popup-missing", window["window_id"])]
            raise CheckFailed("no popup window appeared within 10 s", details)
        time.sleep(1)
        details.update(window=popup, screenshots=[self.shot("extension-popup", popup["window_id"])])
        self.instance.eval("document.documentElement.removeAttribute('data-smoke-popup');"
                           " document.dispatchEvent(new Event('smoke-popup-refresh')); true", tab)
        raw = wait_until(lambda: self.instance.eval(
            "document.documentElement.getAttribute('data-smoke-popup')", tab), 10, 0.5)
        report = json.loads(raw) if raw else None
        details["popup_report"] = report
        self.cua.call("press_key", {"pid": self.instance.pid, "window_id": popup["window_id"], "key": "escape"})
        closed = wait_until(lambda: popup["window_id"] not in self.copy_windows(), 5, 0.5)
        details["closed_on_escape"] = bool(closed)
        if not report or report.get("error"):
            raise CheckFailed(f"the popup's chrome.tabs.query gave no answer: {report}", details)
        if report.get("title") != title:
            raise CheckFailed(f"the popup saw the active tab {report.get('title')!r}, expected {title!r}", details)
        return {"evidence": f"a {popup['bounds']['width']:.0f}x{popup['bounds']['height']:.0f} popup opened; its "
                            f"chrome.tabs.query saw the active tab {title!r}"
                            f"{'' if closed else '; Escape did not close it'}", **details}

    def check_notification_permission(self) -> dict:
        window = self.require_window()
        tab = self.permissions_tab()
        clicked_at = time.time()
        self.instance.cli("click", "--tab", tab, "#notify")

        def prompt():
            current = self.cua.state(self.instance.pid, window["window_id"], query="site-permission",
                                     max_elements=3000)
            return find_row(current, r"browser\.site-permission\.allow")

        allow = wait_until(prompt, 10, 1)
        details = {"method": "clicks the fixture's button (Notification.requestPermission needs a gesture); "
                             "presses Allow on OpenArc's site permission prompt (browser.site-permission.allow) "
                             "in the background; the system log shows when the copy asks macOS; a macOS prompt "
                             f"naming {COPY_NAME!r} gets Allow pressed, any other prompt is left alone"}
        if not allow:
            details["screenshots"] = [self.shot("site-permission-missing", window["window_id"])]
            raise CheckFailed("OpenArc's site permission prompt did not appear within 10 s", details)
        shots = [self.shot("site-permission-prompt", window["window_id"])]
        allowed_at = time.time()
        before_allow = [r for r in self.system_log.requests(since=clicked_at - 0.5, until=allowed_at)
                        if any(marker in r["message"] for marker in LogWatch.PROMPTING)]
        self.cua.press(self.instance.pid, window["window_id"], allow[0])
        macos_prompt = self.answer_copy_notification_prompt(allowed_at, 12)
        result = self.page_value(tab, "notify", 20)
        shown = self.page_value(tab, "shown", 8, done=lambda v: v is not None) if result == "granted" else None
        time.sleep(2)
        after_allow = self.system_log.requests(since=allowed_at - 0.5)
        shots += [b["screenshot"] for b in self.banners.since(allowed_at) if b["screenshot"]]
        decision = next((r["message"] for r in reversed(after_allow) if "Authorization set for" in r["message"]),
                        None)
        details.update(requests_before_allow=before_allow, requests_after_allow=after_allow,
                       macos_prompt=macos_prompt, page_result=result, notification_shown=shown,
                       screenshots=[s for s in shots if s], banners=self.banners.since(clicked_at))
        consulted = [r for r in after_allow if "Getting notification settings" in r["message"]]
        asked = [r for r in after_allow if "Requesting authorization" in r["message"]]
        if before_allow:
            raise CheckFailed(f"the copy asked macOS before the site was allowed: {before_allow[0]['message']}",
                              details)
        if not consulted and not asked:
            raise CheckFailed("allowing the site did not make the copy turn to macOS for notification permission",
                              details)
        if result == "granted" and shown:
            return {"evidence": f"OpenArc turned to macOS only after Allow"
                                f"{' and asked for permission' if asked else ''}; "
                                f"{'the copy prompt got Allow; ' if macos_prompt else ''}the page got 'granted' "
                                f"and its notification fired onshow", **details}
        if asked:
            state = decision or ("prompt answered" if macos_prompt else "no answer")
            return {"status": "warn",
                    "evidence": f"OpenArc asked macOS only after Allow; macOS answer: {state}; the page got "
                                f"{result!r} and no notification showed", **details}
        return {"status": "warn",
                "evidence": f"OpenArc turned to macOS only after Allow (it read the notification settings) and did "
                            f"not ask, since macOS's status for {COPY_BUNDLE_ID} is not 'not determined' (turned "
                            f"off earlier, or a prompt from launch is still pending); the page got {result!r} and "
                            f"no notification showed. Turn notifications on once in System Settings > "
                            f"Notifications > {COPY_NAME} to check delivery", **details}

    def answer_copy_notification_prompt(self, since: float, timeout: float) -> dict | None:
        """Presses Allow on macOS's prompt when, and only when, it names the copy."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for pid in run(["/usr/bin/pgrep", "-x", "NotificationCenter"], check=False).stdout.split():
                for window in self.cua.windows(int(pid)):
                    if not window.get("is_on_screen"):
                        continue
                    state = self.cua.state(int(pid), window["window_id"], max_elements=300)
                    rows = tree_rows(state)
                    if not any(COPY_NAME in text for _, text in rows):
                        continue
                    # macOS 26 shows the prompt's Allow only while the pointer hovers the banner and
                    # gives accessibility no button for it, so this finds nothing there.
                    allow = next(((token, text) for token, text in rows
                                  if re.search(r'AXButton.*"Allow"', text)), None)
                    shot = self.out_dir / "macos-notification-prompt.png"
                    self.cua.screenshot(int(pid), window["window_id"], shot)
                    if allow:
                        self.cua.press(int(pid), window["window_id"], allow[0])
                    return {"rows": [text for _, text in rows if COPY_NAME in text or "Allow" in text][:10],
                            "pressed_allow": bool(allow), "screenshot": str(shot),
                            "note": None if allow else "the banner has no Allow button in its accessibility tree "
                                                       "(macOS shows it on pointer hover only), so it is left "
                                                       "for a person"}
            time.sleep(1)
        return None

    def check_translate(self) -> dict:
        tab = self.open_tab("translate", self.server.url("german.html"))
        read = lambda: self.instance.eval(  # noqa: E731
            "(document.getElementById('heading') || {textContent: ''}).textContent.trim()", tab)
        url_before = self.instance.eval("location.href", tab)
        original = read()
        details = {"method": "`openarc command translatePage` on a German fixture (the Translate Page command); "
                             "the heading is read until it changes, then the command runs again to show the "
                             "original. Translation uses Google's translation service, so it needs the network",
                   "original": original, "target_language": "the first of macOS's preferred languages"}
        # The engine detects the page's language a moment after it loads; asked
        # before that, OpenArc waits 15 s and then opens the page in a translator site.
        time.sleep(3)
        self.instance.cli("command", "translatePage")
        translated = wait_until(lambda: (lambda text: text if text and text != original else None)(read()), 14, 1)
        details["translated"] = translated
        details["screenshots"] = [self.shot("translate-translated" if translated else "translate-missing")]
        url_translated = self.instance.eval("location.href", tab)
        if not translated:
            time.sleep(4)
            tab_url = next((t["url"] for t in self.instance.cli("tabs") if t["id"] == tab), None)
            details["tab_url_after_fallback"] = tab_url
            moved = tab_url and tab_url != url_before
            raise CheckFailed("the page was not translated in place within 14 s"
                              + (f"; OpenArc then opened it in a translator site: {tab_url}" if moved
                                 else " (Google's translation service needs the network)"), details)
        if url_translated != url_before:
            raise CheckFailed(f"the address changed to {url_translated}", details)
        self.instance.cli("command", "translatePage")
        restored = wait_until(lambda: read() == original, 15, 1)
        details["restored"] = bool(restored)
        self.instance.cli("close", tab)
        if not restored:
            raise CheckFailed("running Translate Page again did not bring the original text back", details)
        return {"evidence": f"{original!r} → {translated!r} in place at the same address; the second command "
                            f"brought the original back", **details}

    def qualify_launch_notification_check(self) -> None:
        """Chromium asks macOS only while it has no decision for the app, so a clean
        launch proves nothing once the copy's bundle id has one."""
        launch = next((r for r in self.results if r["name"] == "no-notification-request-at-launch"), None)
        later = next((r for r in self.results if r["name"] == "notification-after-site-permission"), None)
        if not launch or launch["status"] != "pass":
            return
        prompted_later = any("Sending request for permission" in r["message"]
                             for r in (later or {}).get("details", {}).get("requests_after_allow", []))
        if prompted_later:
            launch["evidence"] += "; conclusive: macOS had no decision for the copy, as the later prompt shows"
            return
        launch["status"] = "warn"
        launch["evidence"] += (f"; not conclusive: macOS already had a notification decision for {COPY_BUNDLE_ID} "
                               f"(or the later check did not run), and the engine asks only while there is none. "
                               f"--fresh-identity makes this check conclusive")

    # MARK: Final checks

    def check_background(self) -> dict:
        details = {"samples": self.focus.samples, "frontmost_hits": len(self.focus.hits),
                   "method": "lsappinfo front every 0.5 s while the copy ran"}
        if self.focus.hits:
            raise CheckFailed(f"the copy was the frontmost app in {len(self.focus.hits)} of "
                              f"{self.focus.samples} samples", details)
        return {"evidence": f"the copy was never frontmost ({self.focus.samples} samples)", **details}

    def check_stability(self) -> dict:
        alive = self.instance.alive()
        reports = new_crash_reports(self.instance.started_at - 5, self.instance.app)
        details = {"alive": alive, "crash_reports": reports,
                   "method": "crash reports in ~/Library/Logs/DiagnosticReports newer than the launch that name "
                             "the copy's path"}
        if not alive or reports:
            raise CheckFailed(f"main process alive: {alive}; new crash reports: {reports or 'none'}", details)
        return {"evidence": "the main process is alive and no crash report names the copy", **details}


def find_identity() -> str | None:
    result = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], check=False)
    for line in result.stdout.splitlines():
        match = re.search(r'\s([0-9A-F]{40})\s+"Apple Development:', line)
        if match:
            return match.group(1)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="script/cef_smoke_test.sh",
        description="Launch a background copy of an OpenArc build and check that its engine works.",
        epilog=HELP_EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path, help="OpenArc.app to test, e.g. .build/xcode/Build/Products/Debug/OpenArc.app")
    parser.add_argument("--out", type=Path, help="report directory (default: a new folder in $TMPDIR)")
    parser.add_argument("--expect-chrome-major", type=int, help="override CHROME_VERSION_MAJOR from cef_version.h")
    parser.add_argument("--identity", help="codesign identity for the copy (default: the first Apple Development one)")
    parser.add_argument("--no-gui", action="store_true", help="skip the checks that read windows with cua-driver")
    parser.add_argument("--allow-system-prompts", action="store_true",
                        help="open the screen-share picker even when macOS has no Screen Recording decision "
                             "for the copy; macOS then shows its prompt for a person to answer")
    parser.add_argument("--fresh-identity", action="store_true",
                        help="give the copy a new bundle id for this run, so macOS has no notification decision "
                             "for it and no-notification-request-at-launch is conclusive; the screen-share check "
                             "then skips, and macOS keeps a notification settings entry for that id")
    parser.add_argument("--keep", action="store_true", help="leave the copy running and its data in place")
    parser.add_argument("--wait", type=float, default=30, metavar="MINUTES",
                        help="how long to wait while a run from another checkout uses the copy (default 30)")
    parser.add_argument("--engine", choices=("cef", "chrome", "webkit", "ladybird"), default="cef",
                        help="the engine the copy runs pages on (default cef); chrome needs a build that "
                             f"carries {CHROME_ENGINE_FRAMEWORK}; webkit loads no Chromium; ladybird needs a build "
                             f"that carries {LADYBIRD_ENGINE_FRAMEWORK}")
    options = parser.parse_args()
    options.app = options.app.resolve()
    if not (options.app / "Contents" / "MacOS" / "OpenArc").exists():
        parser.error(f"{options.app} is not an OpenArc app bundle")
    if options.out is None:
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        options.out = Path(tempfile.gettempdir()) / f"openarc-cef-smoke-{stamp}"
    options.out = options.out.resolve()
    if options.engine == "chrome" and not (options.app / "Contents" / "Frameworks" / CHROME_ENGINE_FRAMEWORK).exists():
        parser.error(f"{options.app} carries no {CHROME_ENGINE_FRAMEWORK}; see docs/chrome-engine.md")
    if options.engine == "ladybird" and not (options.app / "Contents" / "Frameworks" /
                                             LADYBIRD_ENGINE_FRAMEWORK).exists():
        parser.error(f"{options.app} carries no {LADYBIRD_ENGINE_FRAMEWORK}; see docs/ladybird-engine.md")
    options.identity = options.identity or find_identity()
    if options.fresh_identity:
        global COPY_BUNDLE_ID
        COPY_BUNDLE_ID = f"{COPY_BUNDLE_ID}.r{dt.datetime.now().strftime('%m%d%H%M')}{random_token(3)}"
    # Held until this process ends; the variable keeps the file open.
    run_lock = RunLock(RUN_LOCK)
    try:
        run_lock.acquire(options.wait * 60, {
            "pid": os.getpid(), "checkout": str(ROOT), "app": str(options.app), "engine": options.engine,
            "started": dt.datetime.now().isoformat(timespec="seconds")})
    except TimeoutError as error:
        log(f"Setup failed: {error}")
        return 2
    except KeyboardInterrupt:
        return 130
    test = SmokeTest(options)
    try:
        return test.run()
    except KeyboardInterrupt:
        test.finish()
        return 130


if __name__ == "__main__":
    sys.exit(main())
