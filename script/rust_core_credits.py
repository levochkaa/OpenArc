#!/usr/bin/env python3
"""Writes the Rust crates that openarc-core links into the apps, with their licenses, into Credits.html.

script/rust_core.sh credits runs it after a crate update. The section sits between the
rust-core-credits markers; crates whose license texts are identical share one block.
"""

import html
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "Core"
CREDITS = ROOT / "Sources/Browser/Resources/Credits.html"
BEGIN = "<!-- rust-core-credits:begin -->"
END = "<!-- rust-core-credits:end -->"
# UniFFI's crates ship without a license file; the text is the repository's.
LICENSE_FALLBACKS = {"MPL-2.0": "https://raw.githubusercontent.com/mozilla/uniffi-rs/main/LICENSE"}


def cargo(*arguments):
    return subprocess.run(["cargo", *arguments], cwd=CORE, check=True, capture_output=True, text=True).stdout


def linked_packages():
    """Name and version of every crate linked into the library, proc macros and build tools left out."""
    tree = cargo(
        "tree", "--locked", "-p", "openarc-core", "-e", "normal,no-proc-macro",
        "--target", "aarch64-apple-darwin", "--prefix", "none", "--format", "{p}",
    )
    packages = set()
    for line in tree.splitlines():
        match = re.match(r"(\S+) v(\S+)", line)
        if match and "(/" not in line:
            packages.add((match.group(1), match.group(2)))
    return packages


def license_text(package):
    """The MIT text of a dual-licensed crate, otherwise its only license."""
    directory = pathlib.Path(package["manifest_path"]).parent
    expression = package.get("license") or ""
    candidates = ["LICENSE-MIT", "LICENSE"] if "MIT" in expression else ["LICENSE", "LICENSE.md", "LICENSE-APACHE"]
    for name in candidates:
        path = directory / name
        if path.is_file():
            return path.read_text().strip()
    if expression in LICENSE_FALLBACKS:
        with urllib.request.urlopen(LICENSE_FALLBACKS[expression]) as response:
            return response.read().decode().strip()
    sys.exit(f"error: no license text for {package['name']} {package['version']} ({expression})")


def section():
    metadata = json.loads(cargo("metadata", "--locked", "--format-version", "1"))
    by_key = {(package["name"], package["version"]): package for package in metadata["packages"]}
    groups = {}
    for key in sorted(linked_packages()):
        package = by_key[key]
        groups.setdefault(license_text(package), []).append(package)

    lines = [
        BEGIN,
        "  <h2>Rust crates</h2>",
        "  <p>",
        "    The Rust core of OpenArc links these crates from",
        '    <a href="https://crates.io">crates.io</a>. Each license below covers the crates listed above it.',
        "  </p>",
    ]
    for text, packages in sorted(groups.items(), key=lambda group: group[1][0]["name"]):
        names = []
        for package in packages:
            homepage = package.get("repository") or package.get("homepage") or f"https://crates.io/crates/{package['name']}"
            names.append(f'<a href="{html.escape(homepage)}">{html.escape(package["name"])}</a> {package["version"]}')
        licenses = sorted({package.get("license") or "" for package in packages})
        lines.append(f"  <p>{', '.join(names)}. License: {html.escape(' / '.join(licenses))}.</p>")
        lines.append(f"  <pre>{html.escape(text, quote=False)}</pre>")
    lines.append(END)
    return "\n".join(lines)


def main():
    credits = CREDITS.read_text()
    if BEGIN not in credits or END not in credits:
        sys.exit(f"error: {CREDITS} has no {BEGIN} … {END} section")
    start = credits.index(BEGIN)
    end = credits.index(END) + len(END)
    CREDITS.write_text(credits[:start] + section() + credits[end:])


if __name__ == "__main__":
    main()
