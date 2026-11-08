#!/usr/bin/env python3
"""Run a build/test in the logged-in macOS GUI security session over SSH.

Usage: mac-gui-run.py NAME LOG COMMAND [ARG ...]
Uses the existing unlocked login Keychain. Does not unlock it or change ACLs.
The exit status is written to LOG.exit. Re-running an owned NAME replaces its job.
"""
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys

name, logfile, *command = sys.argv[1:]
if not re.fullmatch(r"[a-z0-9-]+", name) or not command:
    raise SystemExit("Invalid task name or missing command")
label = "com.roamtty.validation." + name
domain = "gui/" + str(os.getuid())
log = Path(logfile).resolve()
log.parent.mkdir(parents=True, exist_ok=True)
log.touch(mode=0o600, exist_ok=True)
log.chmod(0o600)
status = Path(str(log) + ".exit")
status.unlink(missing_ok=True)
path = Path("/tmp") / (label + ".plist")
body = "umask 077\n" + shlex.join(command) + "\nroamtty_exit=$?\nprintf '%s' \"$roamtty_exit\" > " + shlex.quote(str(status)) + "\nexit \"$roamtty_exit\"\n"
config = {"Label": label, "ProgramArguments": ["/bin/bash", "-c", body], "WorkingDirectory": str(Path.cwd()),
          "RunAtLoad": True, "StandardOutPath": str(log), "StandardErrorPath": str(log),
          "EnvironmentVariables": {"LANG": "en_US.UTF-8"}}
path.write_bytes(plistlib.dumps(config))
subprocess.run(["launchctl", "bootout", domain + "/" + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
print("Started " + label + "; exit status: " + str(status))
