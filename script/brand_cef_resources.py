#!/usr/bin/env python3
"""Replaces the browser's name in CEF's locale resources, so no Chromium rebuild is needed.

Usage: brand_cef_resources.py FRAMEWORK_DIR PRODUCT_NAME

Credits to the Chromium project and its authors stay as they are.
"""

import pathlib
import re
import struct
import sys

HEADER = struct.Struct("<IIHH")
ENTRY = struct.Struct("<HI")
ALIAS = struct.Struct("<HH")
KEEP_AFTER = re.compile(r"\s*(</a>|Authors|open source|project|OS\b|Embedded)")


def brand(text, name):
    def replace(match):
        return match.group(0) if KEEP_AFTER.match(text, match.end()) else name

    return re.sub(r"Chromium(?!OS)", replace, text)


def brand_pak(data, name):
    version, encoding, count, aliases = HEADER.unpack_from(data)
    if version != 5:
        raise ValueError(f"unexpected pak version {version}")
    entries = [ENTRY.unpack_from(data, HEADER.size + i * ENTRY.size) for i in range(count + 1)]
    aliases_start = HEADER.size + (count + 1) * ENTRY.size
    alias_table = data[aliases_start : aliases_start + aliases * ALIAS.size]
    codec = "utf-8" if encoding == 1 else "utf-16-le"
    body = bytearray()
    start = aliases_start + len(alias_table)
    table = bytearray()
    for index in range(count):
        resource, offset = entries[index]
        table += ENTRY.pack(resource, start + len(body))
        chunk = data[offset : entries[index + 1][1]]
        if b"Chromium" in chunk or (encoding != 1 and "Chromium".encode(codec) in chunk):
            try:
                chunk = brand(chunk.decode(codec), name).encode(codec)
            except UnicodeDecodeError:
                pass
        body += chunk
    table += ENTRY.pack(entries[count][0], start + len(body))
    return HEADER.pack(version, encoding, count, aliases) + bytes(table) + alias_table + bytes(body)


def main():
    framework, name = pathlib.Path(sys.argv[1]), sys.argv[2]
    paks = list(framework.glob("**/*.lproj/locale.pak"))
    if not paks:
        raise SystemExit(f"error: no locale resources under {framework}")
    for pak in paks:
        if pak.is_symlink():
            continue
        pak.write_bytes(brand_pak(pak.read_bytes(), name))


if __name__ == "__main__":
    main()
