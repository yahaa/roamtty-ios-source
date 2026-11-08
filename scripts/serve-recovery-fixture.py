#!/usr/bin/env python3
"""Bounded, isolated live network faults for NetworkRecoveryUITests.

Run on the Linux fixture host (uses sudo -n when necessary):
  python3 scripts/serve-recovery-fixture.py --bind 127.0.0.1

Only the generated private JSON contains the control token. Copy its four
ROAMTTY_RECOVERY_* entries into the UI runner environment; keep the existing
ROAMTTY_TEST_USERNAME/PASSWORD. No product hooks or altered system binaries.
The fixed control protocol accepts only status/a/b/offline/online. A/B are real
loopback sshd instances with different keys. The stable TCP proxy intentionally
does not forward UDP: real mosh-server -s binds to its SSH loopback interface.
"""
import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import pwd
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


def dispatch(root):
    """sshd ForceCommand: run real commands; audit only kinds, never their text."""
    root = Path(root)
    os.environ["ROAMTTY_RECOVERY_RUN"] = (root / "run-id").read_text().strip()

    def record(kind):
        with (root / "work" / "audit").open("a") as stream:
            stream.write(f"{kind} {time.monotonic():.6f}\n")

    original = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    if original == "internal-sftp":
        os.execv("/usr/lib/openssh/sftp-server", ["sftp-server"])
    if not original:
        record("shell")
        os.execv("/bin/bash", ["bash", "--noprofile", "--rcfile", str(root / "shell.rc"), "-i"])
    mosh = "mosh-server new " in original
    metrics = "cpu1=" in original and "hostname=" in original and "kb_" in original
    if mosh:
        record("mosh_start")
    result = subprocess.run(["/bin/sh", "-c", original], check=False)
    if result.returncode == 0:
        if mosh:
            record("mosh")
        if metrics:
            record("metrics")
    return result.returncode


class Fixture:
    def __init__(self, options):
        self.options = options
        self.account = pwd.getpwnam(options.username)
        self.run_id = uuid.uuid4().hex
        self.root = Path(tempfile.mkdtemp(prefix="roamtty-recovery-"))
        self.root.chmod(0o755)
        self.work = self.root / "work"
        self.work.mkdir(mode=0o700)
        os.chown(self.work, self.account.pw_uid, self.account.pw_gid)
        self.token = secrets.token_urlsafe(24)
        self.private_file = self.root.with_suffix(".json")
        self.processes = []
        self.logs = []
        self.front = None
        self.controller = None
        self.flows = set()
        self.epoch = 0
        self.online = False
        self.backend = "a"
        self.fingerprints = {}
        self.transition = asyncio.Lock()

    def provision(self):
        (self.root / "run-id").write_text(self.run_id)
        shutil.copyfile(__file__, self.root / "dispatcher.py")
        (self.root / "dispatcher.py").chmod(0o755)
        audit = self.work / "audit"
        audit.touch(mode=0o600)
        os.chown(audit, self.account.pw_uid, self.account.pw_gid)
        # Count successful real startup cd calls. This changes no command result
        # and cannot manufacture a successful SSH connection or remote output.
        (self.root / "shell.rc").write_text(
            "HISTFILE=/dev/null\nPS1='recovery$ '\n"
            "cd() { builtin cd \"$@\" || return; "
            f"if [ \"$PWD\" = {shlex.quote(str(self.work))} ]; then "
            f"printf 'startup 0\\n' >> {shlex.quote(str(audit))}; fi; }}\n"
        )
        public_keys = sorted(Path(self.options.keys).glob("*.pub"))
        if not public_keys:
            raise RuntimeError("Public fixture keys are missing")
        (self.root / "authorized_keys").write_bytes(b"\n".join(path.read_bytes() for path in public_keys))
        for index, name in enumerate(("a", "b")):
            key = self.root / ("host-" + name)
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
            public = key.with_suffix(".pub").read_text().split()[1]
            digest = hashlib.sha256(base64.b64decode(public)).digest()
            self.fingerprints[name] = "SHA256:" + base64.b64encode(digest).decode().rstrip("=")
            config = self.root / ("sshd-" + name + ".conf")
            config.write_text(f"""Port {self.options.backend_port + index}
ListenAddress 127.0.0.1
HostKey {key}
PidFile {self.root / ('sshd-' + name + '.pid')}
AuthorizedKeysFile {self.root / 'authorized_keys'}
StrictModes no
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
AllowUsers {self.options.username}
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
PrintLastLog no
Subsystem sftp internal-sftp
ForceCommand /usr/bin/python3 {self.root / 'dispatcher.py'} --dispatch {self.root}
LogLevel ERROR
""")
            subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(config)], check=True)
            log = (self.root / ("sshd-" + name + ".log")).open("wb")
            self.logs.append(log)
            self.processes.append(subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=subprocess.DEVNULL, stderr=log, start_new_session=True))

    async def start(self):
        self.provision()
        for port in (self.options.backend_port, self.options.backend_port + 1):
            until = time.monotonic() + 5
            while True:
                if any(process.poll() is not None for process in self.processes):
                    raise RuntimeError("Dedicated sshd exited during startup")
                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    writer.close()
                    await writer.wait_closed()
                    break
                except OSError:
                    if time.monotonic() >= until:
                        raise RuntimeError("Dedicated sshd did not listen")
                    await asyncio.sleep(0.05)
        self.controller = await asyncio.start_server(self.control, self.options.bind, self.options.control_port, limit=4096)
        await self.change("a")
        configuration = {
            "ROAMTTY_RECOVERY_HOST": self.options.bind,
            "ROAMTTY_RECOVERY_PORT": str(self.options.port),
            "ROAMTTY_RECOVERY_CONTROL_PORT": str(self.options.control_port),
            "ROAMTTY_RECOVERY_TOKEN": self.token,
        }
        descriptor = os.open(self.private_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(configuration, stream)
        os.chown(self.private_file, int(os.environ.get("SUDO_UID", os.getuid())), int(os.environ.get("SUDO_GID", os.getgid())))
        print(f"Recovery fixture ready: {self.options.bind}:{self.options.port}; PID {os.getpid()}; private runner environment: {self.private_file}; expires in {self.options.lifetime}s", flush=True)

    async def proxy(self, reader, writer):
        if not self.online:
            writer.close()
            return
        epoch = self.epoch
        remote = None
        workers = []
        pair = None
        try:
            upstream, remote = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", self.options.backend_port + (self.backend == "b")), timeout=3)
            if not self.online or epoch != self.epoch:
                return
            pair = (writer, remote)
            self.flows.add(pair)

            async def pump(source, destination):
                while block := await source.read(65536):
                    destination.write(block)
                    await destination.drain()

            workers = [asyncio.create_task(pump(reader, remote)), asyncio.create_task(pump(upstream, writer))]
            await asyncio.wait(workers, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            for worker in workers:
                worker.cancel()
            if workers:
                await asyncio.gather(*workers, return_exceptions=True)
            if pair:
                self.flows.discard(pair)
            for stream in (writer, remote):
                if stream:
                    stream.close()

    async def change(self, action):
        async with self.transition:
            self.online = False
            self.epoch += 1
            previous = self.front
            if previous:
                previous.close()
                self.front = None
            # Killing only an sshd listener leaves authenticated children alive.
            # Abort each captured flow, so an established monitor really loses TCP.
            for pair in list(self.flows):
                for writer in pair:
                    writer.transport.abort()
            # Python 3.12 waits for accepted clients as well as the listener.
            # Abort those clients before waiting, or a long-lived shell deadlocks
            # the very control request that is supposed to interrupt it.
            if previous:
                await previous.wait_closed()
            if action in ("a", "b"):
                self.backend = action
            if action != "offline":
                self.front = await asyncio.start_server(self.proxy, self.options.bind, self.options.port)
                self.online = True

    def tagged_processes(self):
        marker = ("ROAMTTY_RECOVERY_RUN=" + self.run_id).encode()
        result = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if entry.stat().st_uid == self.account.pw_uid and marker in (entry / "environ").read_bytes().split(b"\0"):
                    result.append(entry)
            except (OSError, PermissionError):
                pass
        return result

    def loopback_mosh_servers(self):
        inodes = set()
        for entry in self.tagged_processes():
            try:
                if "mosh-server" not in (entry / "comm").read_text():
                    continue
                for descriptor in (entry / "fd").iterdir():
                    link = os.readlink(descriptor)
                    if link.startswith("socket:["):
                        inodes.add(link[8:-1])
            except OSError:
                pass
        count = 0
        for row in Path("/proc/net/udp").read_text().splitlines()[1:]:
            fields = row.split()
            if len(fields) > 9 and fields[9] in inodes and fields[1].startswith("0100007F:"):
                count += 1
        return count

    def snapshot(self):
        counts = {name: 0 for name in ("mosh", "shell", "startup", "metrics")}
        last_mosh = last_shell = 0.0
        for line in (self.work / "audit").read_text().splitlines():
            fields = line.split()
            if len(fields) != 2:
                continue
            kind, timestamp = fields
            if kind in counts:
                counts[kind] += 1
            if kind == "mosh_start":
                last_mosh = float(timestamp)
            if kind == "shell":
                last_shell = float(timestamp)
        return {"ok": True, "online": self.online, "backend": self.backend,
                "fingerprints": self.fingerprints, "work_directory": str(self.work),
                "counters": counts, "loopback_mosh_servers": self.loopback_mosh_servers(),
                "last_mosh_start": last_mosh, "last_shell_start": last_shell}

    async def control(self, reader, writer):
        try:
            request = json.loads(await asyncio.wait_for(reader.readline(), timeout=3))
            supplied = request.get("token")
            if not isinstance(supplied, str) or not hmac.compare_digest(supplied, self.token):
                response = {"ok": False, "error": "unauthorized"}
            elif request.get("action") not in ("status", "a", "b", "offline", "online"):
                response = {"ok": False, "error": "unsupported action"}
            else:
                if request["action"] != "status":
                    await self.change(request["action"])
                response = self.snapshot()
            writer.write(json.dumps(response).encode() + b"\n")
            await writer.drain()
        except (ValueError, TypeError, OSError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()

    async def close(self):
        await self.change("offline")
        if self.controller:
            self.controller.close()
            await self.controller.wait_closed()
        # The unique environment marker identifies only commands spawned by these
        # two backends, including mosh's detached child. Never kill by account name.
        for entry in self.tagged_processes():
            try:
                os.kill(int(entry.name), signal.SIGTERM)
            except ProcessLookupError:
                pass
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
        await asyncio.sleep(0.3)
        for entry in self.tagged_processes():
            try:
                os.kill(int(entry.name), signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait()
        for log in self.logs:
            log.close()
        self.private_file.unlink(missing_ok=True)
        shutil.rmtree(self.root)


async def serve(options):
    fixture = Fixture(options)
    try:
        await fixture.start()
        stopped = asyncio.Event()
        for signum in (signal.SIGTERM, signal.SIGINT):
            asyncio.get_running_loop().add_signal_handler(signum, stopped.set)
        try:
            await asyncio.wait_for(stopped.wait(), timeout=options.lifetime)
        except asyncio.TimeoutError:
            pass
    finally:
        await fixture.close()


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--dispatch":
        return dispatch(sys.argv[2])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=23005)
    parser.add_argument("--backend-port", type=int, default=23006)
    parser.add_argument("--control-port", type=int, default=23008)
    parser.add_argument("--username", default="itermux_test")
    parser.add_argument("--keys", default=str(Path(__file__).resolve().parents[2] / "roamtty/ssh-core/src/test/resources/keys"))
    parser.add_argument("--lifetime", type=int, default=3600)
    options = parser.parse_args()
    socket.inet_aton(options.bind)
    if options.username != "itermux_test":
        parser.error("Only the dedicated itermux_test account is allowed")
    if not 60 <= options.lifetime <= 7200:
        parser.error("Lifetime must be 60–7200 seconds")
    ports = [options.port, options.backend_port, options.backend_port + 1, options.control_port]
    if len(set(ports)) != 4 or any(not 1024 < port < 65536 for port in ports):
        parser.error("Four distinct unprivileged ports are required")
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", "-n", sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    asyncio.run(serve(options))
    return 0


if __name__ == "__main__":
    sys.exit(main())
