#!/usr/bin/env python3
"""Seed a stale desktop cache in an isolated simulator store, using a real headless SSH fixture.

Usage: seed-headless-desktop-fixture.py SIMULATOR_UDID PRIVATE_FIXTURE_JSON
Install the debug app first. Fixture JSON has host, port, username and password.
Credentials are passed through the existing debug launch hook and are never printed.
Run DesktopLaunchUITests with ROAMTTY_HEADLESS_DESKTOP_FIXTURE=1 afterwards.
"""
import base64
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

os.umask(0o077)
simulator, fixture_path = sys.argv[1:]
fixture = json.loads(Path(fixture_path).read_text())
environment = os.environ.copy()
for key in ("host", "port", "username", "password"):
    environment["SIMCTL_CHILD_ROAMTTY_TEST_" + key.upper()] = str(fixture[key])
environment["SIMCTL_CHILD_ROAMTTY_STORAGE_NAME"] = "DesktopHeadlessRegression"
subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", simulator,
                "com.roamtty.app.ios", "--ui-testing"], env=environment, check=True, capture_output=True)
time.sleep(2)
subprocess.run(["xcrun", "simctl", "terminate", simulator, "com.roamtty.app.ios"], check=True)
container = Path(subprocess.check_output([
    "xcrun", "simctl", "get_app_container", simulator, "com.roamtty.app.ios", "data"
], text=True).strip())
database = container / "Library/Application Support/DesktopHeadlessRegression/roamtty.sqlite"
# Trust only this disposable fixture's public host key, without interacting with the user's store.
scan = subprocess.check_output(["ssh-keyscan", "-T", "5", "-p", str(fixture["port"]),
                                "-t", "ed25519", fixture["host"]], stderr=subprocess.DEVNULL, text=True)
key = next(line.split() for line in scan.splitlines() if not line.startswith("#"))
with sqlite3.connect(database) as db:
    host = json.loads(db.execute("SELECT json FROM hosts WHERE id='ui-live-host'").fetchone()[0])
    host.update(system="UBUNTU", desktop="yes", desktopProbedAt=int(time.time() * 1000))
    db.execute("UPDATE hosts SET json=? WHERE id='ui-live-host'", (json.dumps(host).encode(),))
    db.execute("INSERT OR REPLACE INTO settings VALUES (1, ?)",
               (json.dumps(dict(theme="dark", language="zh-Hans")).encode(),))
    endpoint = f'[{str(fixture["host"]).lower().rstrip(".")}]:{fixture["port"]}'
    db.execute("INSERT OR REPLACE INTO pins VALUES (?, ?, ?)", (endpoint, key[1], base64.b64decode(key[2])))
print("Seeded isolated headless desktop regression store; credentials remain private")
