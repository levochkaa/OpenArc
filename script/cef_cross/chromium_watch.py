#!/usr/bin/env python3
"""Keeps OpenArc's CEF on the newest stable Chromium.

Runs on both machines; see docs/chromium-updates.md.

On the Linux build host (a systemd user timer runs `check`):
  check     look for a CEF/Chromium stable newer than the baseline and start
            the update pipeline in the build tmux session
  run       the pipeline: snapshot the old upstream files, fetch the new base,
            three-way merge Chromium/chromium_src, prepare, build, package
  status    the last update's status (JSON with --json)
  done      an agent finished the update; lets the next one start
  retry     forget the last attempt so the next check builds it again
  snapshot  write upstream (CEF-patched) copies of the overridden files

On the Mac (a LaunchAgent runs `mac-tick`):
  mac-tick  push main's build tools, overrides and the export's version to the
            host, read its status, start one agent thread per update as soon
            as it starts and pass the pipeline's milestones to that thread
  sync      only the push part of mac-tick

Both:
  notify    send a Telegram message (KODYA_BOT_TOKEN, KODYA_CHAT_ID)

Standard library only; run with python3 -I.
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import datetime as dt
import fcntl
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

INDEX_URL = "https://cef-builds.spotifycdn.com/index.json"
CEF_GIT_URL = "https://github.com/chromiumembedded/cef"
CEF_COMPAT_URL = "https://raw.githubusercontent.com/chromiumembedded/cef/{ref}/CHROMIUM_BUILD_COMPATIBILITY.txt"
CHROME_STABLE_URL = "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1"
CEF_PLATFORM = "macosarm64"
USER_AGENT = "openarc-chromium-watch/1"

IS_MAC = platform.system() == "Darwin"
HOME = Path.home()
TMUX_SESSION = os.environ.get("OPENARC_CEF_REMOTE_SESSION", "openarc-cef")
REMOTE_HOST = os.environ.get("OPENARC_CEF_REMOTE_HOST", "wsl")
# Relative to the host's home directory unless absolute.
REMOTE_ROOT = os.environ.get("OPENARC_CEF_REMOTE_ROOT", "cef-mac")
# Results the pipeline leaves for an agent; the watcher holds further builds
# until `done` or `retry` releases them.
AGENT_RESULTS = ("built", "conflicts", "failed")
FINAL_RESULTS = AGENT_RESULTS + ("released", "abandoned")
# Results whose update still has an agent working on it.
OPEN_RESULTS = ("running",) + AGENT_RESULTS


# --- paths and small helpers -------------------------------------------------


def state_dir() -> Path:
    if override := os.environ.get("OPENARC_AUTOMATION_STATE_DIR"):
        return Path(override)
    if IS_MAC:
        return HOME / "Library/Application Support/OpenArc-Automation"
    return Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "openarc-automation"


def cef_root() -> Path:
    if root := os.environ.get("CEF_CROSS_ROOT"):
        return Path(root)
    root = Path(REMOTE_ROOT)
    return root if root.is_absolute() else HOME / root


def automation_dir() -> Path:
    """The host's copy of main's build tools and overrides, pushed by the Mac."""
    return cef_root() / "openarc/main"


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def log(message: str) -> None:
    print(f"[{dt.datetime.now():%F %T}] {message}", flush=True)


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


@contextlib.contextmanager
def locked(name: str, wait: bool = False):
    """An exclusive lock, so two timer runs never act on the same version."""
    path = state_dir() / f"{name}.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log(f"another {name} run holds {path}; skipping")
            yield False
            return
        yield True


def run(cmd, *, cwd=None, check=True, capture=True, input=None, env=None, timeout=None):
    result = subprocess.run(
        cmd,
        cwd=cwd,
        input=input,
        env=env,
        timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        err = result.stderr.decode(errors="replace").strip() if capture and result.stderr else ""
        raise RuntimeError(f"{' '.join(map(str, cmd))} exited {result.returncode}: {err[-2000:]}")
    return result


def http_get(url: str, headers: dict | None = None, timeout: int = 60):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    return urllib.request.urlopen(request, timeout=timeout)


def version_tuple(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", text))


# --- Telegram ----------------------------------------------------------------


def env_value(name: str) -> str:
    """A value from the environment, or from ~/.env, which login shells load."""
    if value := os.environ.get(name):
        return value
    try:
        lines = (HOME / ".env").read_text().splitlines()
    except FileNotFoundError:
        return ""
    for line in lines:
        match = re.match(rf"^\s*(?:export\s+)?{re.escape(name)}=(.*)$", line)
        if match:
            value = match.group(1).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            return value
    return ""


def notify(text: str) -> bool:
    """Sends a Telegram message. Never prints the token; returns False on failure."""
    if os.environ.get("OPENARC_AUTOMATION_NO_NOTIFY") == "1":
        log(f"notify (disabled): {text}")
        return True
    token, chat = env_value("KODYA_BOT_TOKEN"), env_value("KODYA_CHAT_ID")
    if not token or not chat:
        log("notify: KODYA_BOT_TOKEN or KODYA_CHAT_ID is not set; message not sent")
        return False
    data = urllib.parse.urlencode(
        {"chat_id": chat, "text": text[:4000], "disable_web_page_preview": "true"}
    ).encode()
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage", data=data, headers={"User-Agent": USER_AGENT}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            ok = json.load(response).get("ok", False)
    except (urllib.error.URLError, OSError, ValueError) as error:
        # The URL holds the token; report only the error's kind.
        log(f"notify failed: {type(error).__name__} {getattr(error, 'code', '')}")
        return False
    log("notify: sent" if ok else "notify: Telegram refused the message")
    return bool(ok)


# --- release discovery -------------------------------------------------------


def read_cef_header(path: Path) -> dict:
    text = path.read_text()

    def define(name):
        match = re.search(rf'^#define {name} "?([^"\s]*)"?', text, re.M)
        return match.group(1) if match else ""

    chromium = ".".join(define(f"CHROME_VERSION_{part}") for part in ("MAJOR", "MINOR", "BUILD", "PATCH"))
    return {
        "cef_version": define("CEF_VERSION"),
        "cef_commit": define("CEF_COMMIT_HASH"),
        "chromium_tag": chromium,
        "cef_branch": chromium.split(".")[2],
    }


def parse_cef_version(cef_version: str) -> dict:
    """156.0.31+ge603d97+chromium-156.0.8078.100 -> its parts."""
    match = re.match(r"^(\d+\.\d+\.\d+)\+g([0-9a-f]+)\+chromium-([\d.]+)$", cef_version)
    if not match:
        raise ValueError(f"unexpected CEF version {cef_version!r}")
    number, commit, chromium = match.groups()
    return {
        "cef_version": cef_version,
        "cef_number": number,
        "cef_commit": commit,
        "chromium_tag": chromium,
        "cef_branch": chromium.split(".")[2],
    }


def load_baseline(explicit: str | None) -> dict:
    """The version the app ships: the Mac export's cef_version.h, pushed by mac-tick."""
    if explicit:
        return parse_cef_version(explicit)
    pushed = read_json(automation_dir() / "baseline.json", None)
    if pushed:
        return pushed
    local = Path(__file__).resolve().parents[2] / "ThirdParty/cef/export/include/cef_version.h"
    for header in (local, cef_root() / "artifacts/dist/include/cef_version.h"):
        if header.is_file():
            return read_cef_header(header)
    raise SystemExit("error: no baseline; run `script/chromium_watch.sh sync` on the Mac")


def fetch_index(state: dict) -> list[dict] | None:
    """Stable macOS arm64 CEF builds, newest first. None when unchanged since last time."""
    headers = {}
    cache = state_dir() / "cef-index.json"
    if state.get("index_etag") and cache.is_file():
        headers["If-None-Match"] = state["index_etag"]
    try:
        with http_get(INDEX_URL, headers, timeout=120) as response:
            body = response.read()
            state["index_etag"] = response.headers.get("ETag", "")
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(body)
    except urllib.error.HTTPError as error:
        if error.code != 304:
            raise
        body = cache.read_bytes()
    versions = json.loads(body)[CEF_PLATFORM]["versions"]
    stable = []
    for entry in versions:
        if entry.get("channel") != "stable":
            continue
        if not any(f.get("type") == "minimal" for f in entry.get("files", [])):
            continue
        try:
            stable.append(parse_cef_version(entry["cef_version"]))
        except ValueError:
            continue
    stable.sort(key=lambda v: (version_tuple(v["chromium_tag"]), version_tuple(v["cef_number"])), reverse=True)
    return stable


def github_branch_head(branch: str) -> dict | None:
    """The CEF branch's head and the Chromium tag it builds, ahead of the CDN."""
    out = run(["git", "ls-remote", CEF_GIT_URL, f"refs/heads/{branch}"], timeout=60).stdout.decode()
    if not out.strip():
        return None
    commit = out.split()[0]
    with http_get(CEF_COMPAT_URL.format(ref=commit)) as response:
        compat = response.read().decode()
    match = re.search(r"'chromium_checkout':\s*'refs/tags/([\d.]+)'", compat)
    if not match:
        return None
    chromium = match.group(1)
    return {
        "cef_version": f"{branch}-g{commit[:7]}+chromium-{chromium}",
        "cef_number": "",
        "cef_commit": commit,
        "chromium_tag": chromium,
        "cef_branch": branch,
    }


def chrome_stable() -> str:
    try:
        with http_get(CHROME_STABLE_URL, timeout=30) as response:
            return json.load(response)[0]["version"]
    except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError):
        return ""


def is_newer(candidate: dict, baseline: dict) -> bool:
    new, old = version_tuple(candidate["chromium_tag"]), version_tuple(baseline["chromium_tag"])
    if new != old:
        return new > old
    # Same Chromium: a CEF fix release counts, a branch head without a CDN
    # build does not (it has no version number yet).
    if not candidate.get("cef_number") or not baseline.get("cef_version"):
        return False
    try:
        old_number = parse_cef_version(baseline["cef_version"])["cef_number"]
    except ValueError:
        return False
    return version_tuple(candidate["cef_number"]) > version_tuple(old_number)


def update_key(target: dict) -> str:
    return f"{target['chromium_tag']}-{target['cef_commit'][:7]}"


def discover(state: dict, use_github: bool) -> dict:
    stable = fetch_index(state)
    found = {"index": stable[0] if stable else None, "github": None, "chrome_stable": chrome_stable()}
    if use_github and found["index"]:
        try:
            found["github"] = github_branch_head(found["index"]["cef_branch"])
        except (RuntimeError, urllib.error.URLError, OSError) as error:
            log(f"github check failed: {error}")
    return found


def pick_target(found: dict, baseline: dict) -> dict | None:
    """The newest candidate: the CDN's stable build, or the stable branch's head
    when it already builds a newer Chromium than the CDN has."""
    best = found["index"]
    head = found["github"]
    if head and (not best or version_tuple(head["chromium_tag"]) > version_tuple(best["chromium_tag"])):
        best = dict(head, source="github")
    elif best:
        best = dict(best, source="cef-builds index")
    if best and is_newer(best, baseline):
        return best
    return None


# --- host checks ------------------------------------------------------------


def tmux_busy() -> bool:
    if not shutil.which("tmux"):
        return False
    return run(["tmux", "has-session", "-t", TMUX_SESSION], check=False).returncode == 0


def status_path() -> Path:
    return state_dir() / "status.json"


def load_status() -> dict:
    return read_json(status_path(), {})


def cmd_check(args) -> int:
    with locked("watch") as ok:
        if not ok:
            return 0
        state = read_json(state_dir() / "state.json", {})
        baseline = load_baseline(args.baseline)
        status = load_status()
        try:
            found = discover(state, use_github=not args.no_github)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            # Offline or a changed index: try again on the next timer run.
            log(f"release check failed: {type(error).__name__}: {error}")
            return 0
        state["last_check"] = now()
        state["chrome_stable"] = found["chrome_stable"]
        target = pick_target(found, baseline)
        report = {
            "baseline": baseline["cef_version"],
            "cef_stable": found["index"]["cef_version"] if found["index"] else None,
            "cef_branch_head": found["github"]["cef_version"] if found["github"] else None,
            "chrome_stable": found["chrome_stable"],
            "target": target,
        }
        if not args.dry_run:
            write_json(state_dir() / "state.json", state)
        if not target:
            log(f"up to date: {json.dumps(report)}")
            return 0
        key = update_key(target)
        attempts = state.setdefault("attempts", {})
        if status.get("hold") and status.get("key") != key:
            # The agent's thread reads this in `status`; no message of its own.
            log(f"{target['cef_version']} is newer, but {status.get('key')} waits for its agent (hold)")
            return 0
        if key in attempts and not args.force:
            log(f"{key} was already attempted ({attempts[key].get('result', 'started')}); `retry` builds it again")
            return 0
        if tmux_busy():
            log(f"tmux session {TMUX_SESSION} is running; {key} waits for the next check")
            return 0
        if args.dry_run:
            print(json.dumps({"dry_run": True, "would_start": key, **report}, indent=2))
            if args.no_pipeline:
                return 0
            # The pipeline's read-only first steps, in a scratch directory.
            work = Path(tempfile.mkdtemp(prefix="openarc-update-dry-run-"))
            write_json(work / "target.json", {"target": target, "baseline": baseline})
            return run_pipeline(work, dry_run=True)
        start_pipeline(target, baseline, state)
        return 0


def start_pipeline(target: dict, baseline: dict, state: dict) -> None:
    key = update_key(target)
    work = state_dir() / "updates" / key
    work.mkdir(parents=True, exist_ok=True)
    write_json(work / "target.json", {"target": target, "baseline": baseline})
    logs = cef_root() / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log_path = logs / f"update-{key}.log"
    (logs / "latest.log").unlink(missing_ok=True)
    (logs / "latest.log").symlink_to(log_path.name)
    state.setdefault("attempts", {})[key] = {"started_at": now(), "result": "started"}
    write_json(state_dir() / "state.json", state)
    write_json(
        status_path(),
        {
            "key": key,
            **{k: target[k] for k in ("cef_version", "cef_commit", "cef_branch", "chromium_tag")},
            "source": target.get("source"),
            "base": baseline,
            "phase": "queued",
            "result": "running",
            "hold": False,
            "log": str(log_path),
            "work_dir": str(work),
            "started_at": now(),
            "timings": {},
        },
    )
    me = Path(__file__).resolve()
    inner = (
        f"{shlex.quote(sys.executable)} -I {shlex.quote(str(me))} run --work {shlex.quote(str(work))}"
        f" > {shlex.quote(str(log_path))} 2>&1; echo exit $? >> {shlex.quote(str(log_path))}"
    )
    cmd = ["tmux", "new-session", "-d", "-s", TMUX_SESSION, inner]
    # A tmux server started by a systemd service would die with it; a scope of
    # its own keeps the build running after the check exits.
    if os.environ.get("INVOCATION_ID") and shutil.which("systemd-run"):
        cmd = ["systemd-run", "--user", "--scope", "--quiet", "--collect", f"--unit=openarc-cef-update-{int(time.time())}"] + cmd
    run(cmd)
    log(f"started the update to {target['cef_version']} in tmux {TMUX_SESSION}, log {log_path}")


# --- upstream snapshots and the three-way merge ------------------------------


def override_files(root: Path) -> list[str]:
    return sorted(
        str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and p.name not in (".gitkeep", ".DS_Store")
    )


def git_show(repo: Path, rev: str, path: str) -> bytes | None:
    result = run(["git", "-C", str(repo), "show", f"{rev}:{path}"], check=False)
    return result.stdout if result.returncode == 0 else None


def cef_patch_config(cef_repo: Path, rev: str) -> list[tuple[str, str]]:
    text = git_show(cef_repo, rev, "patch/patch.cfg")
    if text is None:
        raise RuntimeError(f"no patch/patch.cfg at CEF {rev}")
    for node in ast.parse(text.decode()).body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "patches" for t in node.targets):
            entries = ast.literal_eval(node.value)
            return [
                (e["name"], e.get("path", "")) for e in entries if "condition" not in e or e["condition"] in os.environ
            ]
    raise RuntimeError("patch.cfg has no patches list")


def repo_for(src: Path, rel: str) -> tuple[Path, str]:
    """The git repository that holds src/<rel> (Chromium or a DEPS checkout)."""
    parts = rel.split("/")
    for depth in range(len(parts) - 1, 0, -1):
        candidate = src.joinpath(*parts[:depth])
        if (candidate / ".git").exists():
            return candidate, "/".join(parts[depth:])
    return src, rel


def upstream_file(src: Path, src_rev: str, cef_repo: Path, cef_rev: str, rel: str, patches, cache: dict) -> bytes | None:
    """src/<rel> as CEF's hook leaves it: the Chromium file with CEF's patches."""
    if rel.startswith("cef/"):
        return git_show(cef_repo, cef_rev, rel[4:])
    repo, in_repo = repo_for(src, rel)
    data = git_show(repo, src_rev if repo == src else "HEAD", in_repo)
    if data is None:
        return None
    for name, patch_dir in patches:
        if patch_dir and not rel.startswith(patch_dir.rstrip("/") + "/"):
            continue
        patch_rel = rel[len(patch_dir.rstrip("/")) + 1 :] if patch_dir else rel
        if name not in cache:
            cache[name] = git_show(cef_repo, cef_rev, f"patch/patches/{name}.patch") or b""
        text = cache[name]
        if not re.search(rb"^diff --git " + re.escape(patch_rel.encode()) + rb" ", text, re.M):
            continue
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp, patch_rel)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            Path(tmp, "p.patch").write_bytes(text)
            run(["git", "init", "-q", tmp])
            run(
                ["git", "apply", "-p0", "--ignore-whitespace", f"--include={patch_rel}", "p.patch"],
                cwd=tmp,
            )
            data = target.read_bytes()
    return data


def snapshot(out: Path, overrides: Path, src_rev: str = "HEAD", cef_rev: str = "HEAD") -> dict:
    root = cef_root()
    src, cef_repo = root / "chromium/src", root / "cef"
    patches = cef_patch_config(cef_repo, cef_rev)
    cache: dict = {}
    missing = []
    if out.exists():
        shutil.rmtree(out)
    for rel in override_files(overrides):
        data = upstream_file(src, src_rev, cef_repo, cef_rev, rel, patches, cache)
        if data is None:
            missing.append(rel)
            continue
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    version = git_show(src, src_rev, "chrome/VERSION") or b""
    chromium = ".".join(re.findall(rb"=(\d+)", version)[i].decode() for i in range(4)) if version else ""
    cef_commit = run(["git", "-C", str(cef_repo), "rev-parse", cef_rev]).stdout.decode().strip()
    info = {"chromium_tag": chromium, "cef_commit": cef_commit, "missing": missing}
    write_json(out / ".snapshot.json", info)
    return info


def merge_overrides(ours: Path, base: Path, theirs: Path, out: Path) -> dict:
    """Three-way merges each override (ours) from the old upstream file (base)
    onto the new one (theirs).

    out/merged: the new Chromium/chromium_src for the repository, conflicts
    left with diff3 markers. out/build: the files the build applies; a
    conflicting override is left out, so the build keeps the upstream file.
    """
    merged_dir, build_dir = out / "merged", out / "build"
    for d in (merged_dir, build_dir):
        if d.exists():
            shutil.rmtree(d)
    files = []
    for rel in override_files(ours):
        o, b, t = ours / rel, base / rel, theirs / rel
        entry = {"path": rel}
        result = o.read_bytes()
        applies = True
        if not t.is_file():
            entry["state"] = "removed-upstream"
            applies = False
        elif not b.is_file():
            entry["state"] = "no-base"
            applies = False
        elif b.read_bytes() == t.read_bytes():
            entry["state"] = "upstream-unchanged"
        elif o.read_bytes() == t.read_bytes():
            entry["state"] = "same-as-upstream"
        else:
            proc = run(
                ["git", "merge-file", "-p", "--diff3", "-L", "openarc", "-L", "old-upstream", "-L", "new-upstream",
                 str(o), str(b), str(t)],
                check=False,
            )
            if proc.returncode < 0 or proc.returncode > 127:
                raise RuntimeError(f"git merge-file failed for {rel}: {proc.stderr.decode(errors='replace')}")
            result = proc.stdout
            if proc.returncode == 0:
                entry["state"] = "merged"
            else:
                entry["state"] = "conflict"
                entry["hunks"] = proc.returncode
                applies = False
        entry["conflict"] = not applies
        for d, write in ((merged_dir, True), (build_dir, applies)):
            if write:
                (d / rel).parent.mkdir(parents=True, exist_ok=True)
                (d / rel).write_bytes(result)
        files.append(entry)
    report = {"files": files, "conflicts": [f["path"] for f in files if f["conflict"]]}
    write_json(out / "merge.json", report)
    return report


def cmd_snapshot(args) -> int:
    info = snapshot(Path(args.out), Path(args.overrides or automation_dir() / "chromium_src"), args.src_rev, args.cef_rev)
    print(json.dumps(info, indent=2))
    return 0


def cmd_merge(args) -> int:
    report = merge_overrides(Path(args.ours), Path(args.base), Path(args.theirs), Path(args.out))
    for f in report["files"]:
        print(f"{f['state']:20} {f['path']}")
    return 1 if report["conflicts"] else 0


# --- the pipeline ------------------------------------------------------------


class StepFailed(Exception):
    pass


def cmd_run(args) -> int:
    return run_pipeline(Path(args.work), dry_run=False)


def run_pipeline(work: Path, dry_run: bool) -> int:
    spec = read_json(work / "target.json", None)
    if not spec:
        raise SystemExit(f"error: no {work / 'target.json'}")
    target, baseline = spec["target"], spec["baseline"]
    status = {"timings": {}} if dry_run else load_status()
    status.setdefault("timings", {})
    tools = Path(__file__).resolve().parent
    overrides = Path(os.environ.get("OPENARC_WATCH_OVERRIDES") or automation_dir() / "chromium_src")
    root = cef_root()
    if not overrides.is_dir() or not override_files(overrides):
        log(f"error: no overrides in {overrides}; run `script/chromium_watch.sh sync` on the Mac")
        return 1

    def save(**fields):
        status.update(fields)
        write_json(work / "dry-run-status.json" if dry_run else status_path(), status)

    def cef_cross(command: str, build_overrides: Path) -> None:
        env = dict(
            os.environ,
            CEF_CROSS_ROOT=str(root),
            CEF_BRANCH=target["cef_branch"],
            CEF_COMMIT=target["cef_commit"],
            CHROMIUM_TAG=target["chromium_tag"],
            OPENARC_OVERRIDES_DIR=str(build_overrides),
        )
        log(f"cef_cross.sh {command}")
        if subprocess.run(["bash", str(tools / "cef_cross.sh"), command], env=env).returncode != 0:
            raise StepFailed(command)

    @contextlib.contextmanager
    def phase(name: str):
        save(phase=name)
        log(f"=== phase {name}")
        started = time.time()
        yield
        status["timings"][name] = round(time.time() - started)
        save()

    try:
        with phase("snapshot-base"):
            src, cef_repo = root / "chromium/src", root / "cef"
            src_rev, cef_rev = "HEAD", "HEAD"
            head_version = git_show(src, "HEAD", "chrome/VERSION") or b""
            head_tag = ".".join(m.decode() for m in re.findall(rb"=(\d+)", head_version))
            if head_tag != baseline["chromium_tag"]:
                log(f"the tree is at Chromium {head_tag}, not the baseline; fetching {baseline['chromium_tag']}")
                run(["git", "-C", str(src), "fetch", "-q", "--depth=1", "--no-tags", "origin",
                     f"+refs/tags/{baseline['chromium_tag']}:refs/openarc/base"], capture=False)
                src_rev = "refs/openarc/base"
            run(["git", "-C", str(cef_repo), "fetch", "-q", "origin", baseline["cef_branch"]], check=False)
            cef_rev = baseline["cef_commit"]
            info = snapshot(work / "base", overrides, src_rev, cef_rev)
            if info["missing"]:
                log(f"overrides missing in the old upstream: {info['missing']}")
        with phase("resolve"):
            run(["git", "-C", str(cef_repo), "fetch", "-q", "origin", target["cef_branch"]], capture=False)
            full = run(["git", "-C", str(cef_repo), "rev-parse", "--verify", f"{target['cef_commit']}^{{commit}}"])
            target["cef_commit"] = full.stdout.decode().strip()
            save(cef_commit=target["cef_commit"])
        if dry_run:
            print(json.dumps({"dry_run": "stopped before fetch", "work_dir": str(work), **status}, indent=2))
            return 0
        empty = work / "no-overrides"
        empty.mkdir(exist_ok=True)
        with phase("fetch"):
            cef_cross("fetch", empty)
        with phase("merge"):
            snapshot(work / "theirs", overrides)
            report = merge_overrides(overrides, work / "base", work / "theirs", work)
            save(merge=report["files"], conflicts=report["conflicts"], merged_dir=str(work / "merged"))
            log(f"merge: {len(report['files'])} overrides, conflicts: {report['conflicts'] or 'none'}")
        build_overrides = work / "build"
        with phase("prepare"):
            try:
                cef_cross("prepare", build_overrides)
            except StepFailed:
                patch_overrides = build_overrides / "cef/patch"
                if not patch_overrides.exists():
                    raise
                # A merged CEF patch that does not apply: build with CEF's own
                # patch and leave the override to the agent.
                for path in override_files(patch_overrides):
                    rel = f"cef/patch/{path}"
                    status["conflicts"] = sorted(set(status.get("conflicts", [])) | {rel})
                    for entry in status.get("merge", []):
                        if entry["path"] == rel:
                            entry.update(state="patch-does-not-apply", conflict=True)
                shutil.rmtree(patch_overrides)
                save()
                log("the merged CEF patch override did not apply; preparing with CEF's own patches")
                cef_cross("prepare", build_overrides)
        with phase("build"):
            cef_cross("build", build_overrides)
        with phase("package"):
            cef_cross("package", build_overrides)
            built = read_cef_header(root / "artifacts/dist/include/cef_version.h")
            save(cef_version=built["cef_version"], dist=str(root / "artifacts/dist"))
    except Exception as error:  # noqa: BLE001 - every failure must reach the status and the owner
        failed_phase = status.get("phase")
        if dry_run:
            log(f"dry run failed in {failed_phase}: {error}")
            return 1
        # The agent's thread fixes the cause and runs `retry`; until then no
        # newer update starts over this one.
        save(result="failed", error=str(error)[-1500:], failed_phase=failed_phase, finished_at=now(), hold=True)
        mark_attempt(status["key"], "failed")
        log(f"failed in {failed_phase}; the Mac passes it to the agent thread")
        return 1
    result = "conflicts" if status.get("conflicts") else "built"
    save(result=result, phase="waiting-for-agent", hold=True, finished_at=now())
    mark_attempt(status["key"], result)
    log(f"done: {result}; the Mac passes it to the agent thread")
    return 0


def tail_log(path: str | None, lines: int) -> str:
    if not path:
        return ""
    try:
        content = Path(path).read_text(errors="replace").splitlines()
    except FileNotFoundError:
        return ""
    return "\n".join(line[:200] for line in content[-lines:])


def mark_attempt(key: str, result: str) -> None:
    state_file = state_dir() / "state.json"
    state = read_json(state_file, {})
    state.setdefault("attempts", {}).setdefault(key, {}).update(result=result, finished_at=now())
    write_json(state_file, state)


def cmd_status(args) -> int:
    status = load_status()
    status["tmux_running"] = tmux_busy()
    state = read_json(state_dir() / "state.json", {})
    status["last_check"] = state.get("last_check")
    status["chrome_stable"] = state.get("chrome_stable")
    if args.json:
        print(json.dumps(status, indent=2, sort_keys=True))
        return 0
    if not status.get("key"):
        print(f"no update yet; last check {status['last_check']}")
        return 0
    print(f"update      {status.get('base', {}).get('cef_version')} -> {status.get('cef_version')}")
    print(f"phase       {status.get('phase')}  result {status.get('result')}  hold {status.get('hold')}")
    print(f"log         {status.get('log')}")
    print(f"work dir    {status.get('work_dir')}")
    print(f"conflicts   {', '.join(status.get('conflicts') or []) or 'none'}")
    print(f"timings     {status.get('timings')}")
    print(f"last check  {status['last_check']}  Chrome stable {status['chrome_stable']}")
    return 0


def cmd_done(args) -> int:
    with locked("watch", wait=True):
        status = load_status()
        if not status.get("key"):
            raise SystemExit("error: no update in progress")
        status.update(result=args.result, hold=False, phase="done", closed_at=now())
        if args.note:
            status["note"] = args.note
        write_json(status_path(), status)
        mark_attempt(status["key"], args.result)
    print(f"{status['key']}: {args.result}; the next check may start a newer update")
    return 0


def cmd_retry(args) -> int:
    with locked("watch", wait=True):
        state_file = state_dir() / "state.json"
        state = read_json(state_file, {})
        key = args.key or load_status().get("key")
        state.get("attempts", {}).pop(key, None)
        write_json(state_file, state)
        status = load_status()
        if status.get("key") == key:
            status["hold"] = False
            write_json(status_path(), status)
    print(f"forgot {key}; the next check builds it again")
    return 0


# --- the Mac side ------------------------------------------------------------


def primary_checkout() -> Path:
    here = Path(__file__).resolve().parent
    common = run(["git", "-C", str(here), "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.decode().strip()
    return Path(common).parent


def remote_path(*parts: str) -> str:
    """A host path for rsync and ssh, relative to the host's home unless absolute."""
    return "/".join((REMOTE_ROOT,) + parts)


def ssh(command: str, *, check=True, input=None, timeout=120):
    return run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", REMOTE_HOST, command],
        check=check, input=input, timeout=timeout,
    )


def remote_watch(args: str) -> str:
    script = shlex.quote(remote_path("openarc/main/tools/chromium_watch.py"))
    root = REMOTE_ROOT if REMOTE_ROOT.startswith("/") else f"$HOME/{REMOTE_ROOT}"
    env = f'CEF_CROSS_ROOT="{root}"'
    if remote_state := os.environ.get("OPENARC_AUTOMATION_REMOTE_STATE_DIR"):
        env += f" OPENARC_AUTOMATION_STATE_DIR={shlex.quote(remote_state)}"
    # bash -lc: the host's login profile loads ~/.env and PATH.
    return f"bash -lc {shlex.quote(f'{env} python3 -I {script} {args}')}"


def mac_state_file() -> Path:
    return state_dir() / "chromium-update.json"


def main_fingerprint(checkout: Path) -> dict:
    trees = {}
    for path in ("script/cef_cross", "Chromium/chromium_src"):
        trees[path] = run(["git", "-C", str(checkout), "rev-parse", f"main:{path}"]).stdout.decode().strip()
    header = checkout / "ThirdParty/cef/export/include/cef_version.h"
    baseline = read_cef_header(header) if header.is_file() else None
    return {"trees": trees, "baseline": baseline}


def sync_main(checkout: Path, dry_run: bool) -> bool:
    """Pushes main's script/cef_cross and Chromium/chromium_src (committed
    files only) and the export's version to the host's openarc/main."""
    state = read_json(mac_state_file(), {})
    fingerprint = main_fingerprint(checkout)
    if not fingerprint["baseline"]:
        log("no ThirdParty/cef/export/include/cef_version.h; nothing to sync")
        return False
    if state.get("synced") == fingerprint:
        return False
    if dry_run:
        log(f"dry run: would push main ({fingerprint['trees']}) and baseline {fingerprint['baseline']['cef_version']}")
        return True
    with tempfile.TemporaryDirectory() as tmp:
        archive = run(["git", "-C", str(checkout), "archive", "--format=tar", "main", "script/cef_cross", "Chromium/chromium_src"]).stdout
        tar_path = Path(tmp, "main.tar")
        tar_path.write_bytes(archive)
        with tarfile.open(tar_path) as tar:
            try:
                tar.extractall(tmp, filter="data")
            except TypeError:  # Python without extraction filters
                tar.extractall(tmp)
        write_json(Path(tmp, "baseline.json"), fingerprint["baseline"])
        ssh(f"mkdir -p {shlex.quote(remote_path('openarc/main'))}")
        dest = f"{REMOTE_HOST}:{remote_path('openarc/main')}"
        run(["rsync", "-a", "--delete", f"{tmp}/script/cef_cross/", f"{dest}/tools/"])
        run(["rsync", "-a", "--delete", "--exclude", ".gitkeep", f"{tmp}/Chromium/chromium_src/", f"{dest}/chromium_src/"])
        run(["rsync", "-a", f"{tmp}/baseline.json", f"{dest}/baseline.json"])
    state["synced"] = fingerprint
    state["synced_at"] = now()
    write_json(mac_state_file(), state)
    log(f"pushed main and baseline {fingerprint['baseline']['cef_version']} to {REMOTE_HOST}")
    return True


THREAD_PROMPT = """\
OpenArc's Chromium update started on the Linux build host.

- Update: CEF {base} -> {cef_version} (Chromium {chromium_tag}), found via {source}
- Host now: phase {phase}, result {result}
- Override conflicts so far: {conflicts}
- Host log: {log}

You own this update from start to finish. Follow the chromium-update skill
(.claude/skills/chromium-update/SKILL.md): resolve the override conflicts as
soon as the merge phase lists them, while the host keeps building; fix every
failure of the host pipeline (fetch, prepare, build) and of the app build;
then verify, publish a Beta release and message the owner. The Mac sends the
pipeline's milestones (merge done, build failed, build finished) to this
thread. Message the owner on Telegram only when the Beta is out or when you
are blocked. Never promote it to the stable channel without the owner's OK.
"""


def start_thread(checkout: Path, status: dict, dry_run: bool) -> dict | None:
    version = status.get("cef_version", "")
    number = version.split("+")[0]
    prompt = THREAD_PROMPT.format(
        base=status.get("base", {}).get("cef_version"),
        cef_version=version,
        chromium_tag=status.get("chromium_tag"),
        source=status.get("source"),
        phase=status.get("phase"),
        result=status.get("result"),
        conflicts=", ".join(status.get("conflicts") or []) or "none",
        log=status.get("log"),
    )
    t3 = os.environ.get("OPENARC_T3_BIN") or shutil.which("t3") or "t3"
    cmd = [
        t3, "thread", "start", "--json",
        "--title", f"Chromium {status.get('chromium_tag')} update",
        "--worktree", "main",
        "--branch", f"tech/chromium-{number or status.get('chromium_tag')}",
        str(checkout), "-",
    ]
    if dry_run:
        log(f"dry run: would run {shlex.join(cmd)} with the prompt:\n{prompt}")
        return None
    out = run(cmd, input=prompt.encode(), timeout=180).stdout.decode()
    try:
        info = json.loads(out)
    except json.JSONDecodeError:
        info = {"output": out.strip()}
    return info


def pipeline_events(status: dict) -> list[tuple[str, str]]:
    """The milestones of the host's current run the agent acts on, as (id, message).
    Ids carry the run's start, so a retried run reports again."""
    run_id = status.get("started_at", "")
    events = []
    conflicts = status.get("conflicts") or []
    if conflicts:
        events.append((
            f"{run_id} conflicts {','.join(sorted(conflicts))}",
            "The host's merge left these overrides for you; resolve them now, the host keeps "
            f"building with the upstream files: {', '.join(conflicts)}. "
            "`script/chromium_watch.sh merged` brings the merged set here.",
        ))
    result = status.get("result")
    if result == "failed":
        events.append((
            f"{run_id} failed",
            f"The host pipeline failed in {status.get('failed_phase') or status.get('phase')}: "
            f"{(status.get('error') or '').strip()[-300:]}\n"
            "Read `LINES_SHOWN=200 script/chromium_watch.sh log`, fix the cause, land it on main, "
            "`script/chromium_watch.sh sync`, `retry` and `check`.",
        ))
    elif result in ("built", "conflicts"):
        events.append((
            f"{run_id} {result}",
            f"The host finished: {result}"
            f"{' (conflicting overrides were built from upstream)' if result == 'conflicts' else ''}. "
            "Continue with the skill: rebuild if you changed overrides, then pull, build, test, smoke, Beta.",
        ))
    return events


def send_to_thread(thread_id: str, message: str, dry_run: bool) -> None:
    t3 = os.environ.get("OPENARC_T3_BIN") or shutil.which("t3") or "t3"
    cmd = [t3, "thread", "send", thread_id, "-"]
    if dry_run:
        log(f"dry run: would run {shlex.join(cmd)}: {message}")
        return
    run(cmd, input=f"[chromium-watch] {message}".encode(), timeout=120)


def cmd_mac_tick(args) -> int:
    with locked("mac-tick") as ok:
        if not ok:
            return 0
        checkout = primary_checkout()
        try:
            raw = ssh(remote_watch("status --json"), timeout=60).stdout.decode()
            status = json.loads(raw)
        except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            # The host sleeps or the watcher is not installed yet.
            log(f"host status unavailable: {str(error)[:300]}")
            status = None
        busy = bool(status and (status.get("tmux_running") or status.get("result") == "running"))
        if status is None or not busy:
            try:
                sync_main(checkout, args.dry_run)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                log(f"sync failed: {str(error)[:300]}")
        if not status or not status.get("key") or status.get("result") not in OPEN_RESULTS:
            if status:
                log(f"host: {status.get('key') or 'no update'} {status.get('phase') or ''} {status.get('result') or ''}")
            return 0
        state = read_json(mac_state_file(), {})
        threads = state.setdefault("threads", {})
        key = status["key"]
        if key not in threads:
            try:
                info = start_thread(checkout, status, args.dry_run)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                failures = state.get("thread_failures", 0) + 1
                state["thread_failures"] = failures
                write_json(mac_state_file(), state)
                log(f"t3 thread start failed ({failures}): {str(error)[:500]}")
                if failures == 3:
                    notify(
                        f"OpenArc: the update to CEF {status.get('cef_version')} started, but its agent "
                        f"thread failed to start 3 times: {str(error)[:300]}"
                    )
                return 1
            if args.dry_run:
                return 0
            link = info.get("link") or info.get("threadId") or info.get("output", "")
            # What the prompt already told the thread is not sent again.
            sent = [event_id for event_id, _ in pipeline_events(status)]
            threads[key] = {"started_at": now(), "thread": info, "sent": sent}
            state["thread_failures"] = 0
            write_json(mac_state_file(), state)
            notify(
                f"OpenArc: started the update to CEF {status.get('cef_version')} "
                f"(Chromium {status.get('chromium_tag')}) from {status.get('base', {}).get('cef_version')}. "
                f"Agent thread: {link}"
            )
            log(f"started agent thread for {key}: {link}")
            return 0
        entry = threads[key]
        thread_id = entry.get("thread", {}).get("threadId")
        if not thread_id:
            return 0
        sent = entry.setdefault("sent", [])
        for event_id, message in pipeline_events(status):
            if event_id in sent:
                continue
            try:
                send_to_thread(thread_id, message, args.dry_run)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                log(f"t3 thread send failed: {str(error)[:300]}")
                return 1
            if args.dry_run:
                continue
            sent.append(event_id)
            write_json(mac_state_file(), state)
            log(f"sent to {thread_id}: {event_id}")
        return 0


def cmd_sync(args) -> int:
    sync_main(primary_checkout(), args.dry_run) or log("host copy is current")
    return 0


def cmd_notify(args) -> int:
    text = " ".join(args.text)
    if args.test:
        text = f"[TEST] {text or 'OpenArc automation test message; nothing to do.'}"
    return 0 if notify(text) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("check", help="look for a newer stable and start the pipeline")
    p.add_argument("--dry-run", action="store_true", help="report what would start; change nothing")
    p.add_argument("--baseline", help="pretend the app ships this CEF version (e.g. 156.0.30+g6028375+chromium-156.0.8078.96)")
    p.add_argument("--no-github", action="store_true", help="only the cef-builds index")
    p.add_argument("--force", action="store_true", help="start even if this version was attempted")
    p.add_argument("--no-pipeline", action="store_true", help="with --dry-run: skip the pipeline's read-only first steps")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("run", help="the pipeline (started by check in tmux)")
    p.add_argument("--work", required=True)
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("done", help="the agent finished; release the hold")
    p.add_argument("--result", choices=("released", "abandoned", "failed"), required=True)
    p.add_argument("--note")
    p.set_defaults(func=cmd_done)

    p = sub.add_parser("retry", help="forget an attempt so check builds it again")
    p.add_argument("--key")
    p.set_defaults(func=cmd_retry)

    p = sub.add_parser("snapshot", help="upstream copies of the overridden files")
    p.add_argument("--out", required=True)
    p.add_argument("--overrides")
    p.add_argument("--src-rev", default="HEAD")
    p.add_argument("--cef-rev", default="HEAD")
    p.set_defaults(func=cmd_snapshot)

    p = sub.add_parser("merge", help="three-way merge overrides between two snapshots")
    for name in ("ours", "base", "theirs", "out"):
        p.add_argument(f"--{name}", required=True)
    p.set_defaults(func=cmd_merge)

    p = sub.add_parser("mac-tick", help="Mac: sync, read the host status, start agent threads")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_mac_tick)

    p = sub.add_parser("sync", help="Mac: push main's tools and overrides to the host")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("notify", help="send a Telegram message")
    p.add_argument("--test", action="store_true", help="label the message as a test")
    p.add_argument("text", nargs="*")
    p.set_defaults(func=cmd_notify)

    args = parser.parse_args()
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
