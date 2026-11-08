#!/usr/bin/env python3
"""Seed isolated simulator stores for HostScreenCardUITests (never the default Roamtty store).

Usage: python3 scripts/seed-host-card-fixtures.py SIMULATOR_UDID
Install the debug app first. Run the test with ROAMTTY_HOST_CARD_FIXTURE=1.
"""
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import time
import zlib

simulator = sys.argv[1]
container = Path(subprocess.check_output([
    "xcrun", "simctl", "get_app_container", simulator, "com.roamtty.app.ios", "data"
], text=True).strip())
# A synthetic desktop image, no user screenshots or credentials.
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

rows = bytearray()
for y in range(360):
    rows.append(0)
    for x in range(640):
        rows.extend((40 + x * 100 // 640, 80 + y * 100 // 360, 150))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 640, 360, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
for store_name, theme in (("HostCardParity-dark", "dark"), ("HostCardParity-light", "light"),
                          ("HostCardRecency", "dark")):
    folder = container / "Library/Application Support" / store_name
    folder.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(folder / "roamtty.sqlite") as db:
        db.executescript("CREATE TABLE IF NOT EXISTS hosts(id TEXT PRIMARY KEY, json BLOB NOT NULL);"
                         "CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL);")
        for host_id, name, system, desktop in (("pictured", "MacBook Pro", "MACOS", "yes"),
                                               ("headless", "Ubuntu Server", "UBUNTU", "no"),
                                               ("placeholder", "Windows PC", "WINDOWS", "yes")):
            host = dict(id=host_id, name=name, system=system, address="127.0.0.1", port=9,
                        username="fixture", auth="password", mode="tmux", savePassword=False,
                        plugins=["tmux", "mosh"], desktop=desktop, desktopProbedAt=int(time.time() * 1000))
            db.execute("INSERT OR REPLACE INTO hosts VALUES (?, ?)", (host_id, json.dumps(host).encode()))
        db.execute("INSERT OR REPLACE INTO settings VALUES (1, ?)",
                   (json.dumps(dict(theme=theme)).encode(),))
    thumbs = folder / "desktop-thumbs"
    thumbs.mkdir(exist_ok=True)
    # UIImage identifies the format from its bytes, independently of the cache's .jpg suffix.
    (thumbs / ("pictured".encode().hex() + ".jpg")).write_bytes(png)
print("Seeded isolated dark/light and recent-use host-card fixtures")
