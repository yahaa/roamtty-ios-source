#!/usr/bin/env python3
"""Run opt-in memory checks in an installed Debug app against a disposable SSH fixture.

Usage: run-memory-validation.py DEVICE PRIVATE_FIXTURE_JSON [--desktop | --app]
The fixture must contain host, port, username, password and fingerprint. The probe
uses a separate local store, creates/removes a unique 128 MiB remote temporary file,
and writes Documents/MemoryValidation/report.json. Do not point it at a user host.
Retrieve the report with devicectl after its final `finished` check appears.
--desktop instead runs a real graphical fixture through VideoToolbox, including
pause/reconnect/resume, and writes Documents/DesktopMemoryValidation/report.json.
--app instead opens and closes real shell and tmux sessions, the file browser and the host page
through the app's own model on screen, checks that their objects go, and measures footprint, frame
hitches and idle CPU; it writes Documents/AppLifecycleValidation/report.json.
"""
import json
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("fixture")
    kind = parser.add_mutually_exclusive_group()
    kind.add_argument("--desktop", action="store_true")
    kind.add_argument("--app", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(Path(args.fixture).read_text())
    required = ("host", "port", "username", "password", "fingerprint")
    if any(str(fixture.get(key, "")) == "" for key in required):
        raise SystemExit("Fixture is incomplete")
    environment = os.environ.copy()
    for key in required:
        environment["DEVICECTL_CHILD_ROAMTTY_TEST_" + key.upper()] = str(fixture[key])
    if os.environ.get("ROAMTTY_LIFECYCLE_ONLY"):
        environment["DEVICECTL_CHILD_ROAMTTY_LIFECYCLE_ONLY"] = os.environ["ROAMTTY_LIFECYCLE_ONLY"]
    environment["DEVICECTL_CHILD_ROAMTTY_STORAGE_NAME"] = "AppLifecycleValidation" if args.app else "MemoryValidation"
    subprocess.run([
        "xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
        "--terminate-existing", "com.roamtty.app.ios",
        "--desktop-memory-validation" if args.desktop else "--app-lifecycle-validation" if args.app else "--memory-validation",
    ], env=environment, check=True)


if __name__ == "__main__":
    main()
