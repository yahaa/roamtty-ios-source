#!/usr/bin/env python3
"""Launch fixture-only diagnostics in a Debug app without putting secrets in argv.

Usage: run-device-validation.py DEVICE PRIVATE_FIXTURE_JSON
The JSON contains host, port, username, password and the expected SHA256 fingerprint.
Install a Debug build first. Results are Documents/Validation/report.json in the app.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

device, fixture_path = sys.argv[1:]
fixture = json.loads(Path(fixture_path).read_text())
required = ("host", "port", "username", "password", "fingerprint")
if any(str(fixture.get(key, "")) == "" for key in required):
    raise SystemExit("Fixture is incomplete")
environment = os.environ.copy()
for key in required:
    environment["DEVICECTL_CHILD_ROAMTTY_TEST_" + key.upper()] = str(fixture[key])
environment["DEVICECTL_CHILD_ROAMTTY_STORAGE_NAME"] = "DeviceValidation"
subprocess.run([
    "xcrun", "devicectl", "device", "process", "launch", "--device", device,
    "--terminate-existing", "com.roamtty.app.ios", "--device-validation",
], env=environment, check=True)
