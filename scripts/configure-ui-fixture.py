#!/usr/bin/env python3
"""Attach local, untracked fixture credentials to a generated xctestrun file.

Usage: configure-ui-fixture.py file.xctestrun private-fixture.json [extra-environment.json ...]
The JSON fields are host, port, username and password. Values are never printed.
"""
import json
import os
from pathlib import Path
import plistlib
import sys

run = Path(sys.argv[1])
fixture = json.loads(Path(sys.argv[2]).read_text())
environment = {"ROAMTTY_TEST_" + key.upper(): str(fixture[key]) for key in ["host", "port", "username", "password"]}
schemas = [
    {"ROAMTTY_RECOVERY_HOST", "ROAMTTY_RECOVERY_PORT", "ROAMTTY_RECOVERY_CONTROL_PORT", "ROAMTTY_RECOVERY_TOKEN"},
    {"ROAMTTY_PLUGIN_HOST", "ROAMTTY_PLUGIN_PORT", "ROAMTTY_PLUGIN_CANCEL_PORT", "ROAMTTY_PLUGIN_FINGERPRINT", "ROAMTTY_PLUGIN_CANCEL_FINGERPRINT"},
    # scripts/test-desktop-gestures.sh: the main fixture is then a live desktop host.
    {"ROAMTTY_DESKTOP_GESTURE_HOST"},
    {"ROAMTTY_DESKTOP_GESTURE_HOST", "ROAMTTY_TAP_POINTS"},
]
for filename in sys.argv[3:]:
    extra = json.loads(Path(filename).read_text())
    if set(extra) not in schemas or any(not str(value) for value in extra.values()):
        raise SystemExit("Additional fixture environment is incomplete or contains unexpected keys")
    environment.update({key: str(value) for key, value in extra.items()})
data = plistlib.loads(run.read_bytes())
count = 0
def configure(value):
    global count
    if isinstance(value, dict):
        if value.get("IsUITestBundle") or "UITests" in str(value.get("BlueprintName", "")):
            value.setdefault("EnvironmentVariables", {}).update(environment)
            count += 1
        for child in value.values():
            configure(child)
    elif isinstance(value, list):
        for child in value:
            configure(child)
configure(data)
if not count:
    raise SystemExit("No UI test target found in xctestrun")
run.write_bytes(plistlib.dumps(data))
os.chmod(run, 0o600)
print(f"Configured {count} UI test target(s); credentials remain untracked.")
