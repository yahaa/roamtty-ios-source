#!/usr/bin/env python3
"""Two bounded, owned Docker hosts for genuine apt/sudo UI installation tests.

Run on the Linux fixture host; Docker must already be available to this user:
  python3 scripts/serve-plugin-fixture.py --bind 127.0.0.1

The normal host deliberately has no SFTP subsystem, while the cancellation host
has real SFTP and throttled apt downloads. Both start without tmux or mosh. The
password is read from the existing private fixture file and sent to chpasswd
only through stdin; it is never in Docker arguments, environment or image layers.
Only generated, UUID-labelled containers and the generated image are cleaned up.
The containers also expire independently if this supervisor is killed.

Successful tests really install packages. Before another installation run, send
SIGTERM to the exact supervisor PID printed by this script, wait for its owned
cleanup, then run this command again. Copy the NEW environment.json to the UI
runner: fresh containers have fresh host keys. Never reuse the old JSON or reset
packages on the host system. The preflight rejects already-installed plugins.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


LABEL = "dev.roamtty.plugin-fixture"


class Fixture:
    def __init__(self, options):
        self.options = options
        self.run_id = uuid.uuid4().hex
        self.root = Path(tempfile.mkdtemp(prefix="roamtty-plugin-"))
        self.root.chmod(0o700)
        self.image = "roamtty-plugin-fixture:" + self.run_id
        self.containers = []
        self.environment_file = self.root / "environment.json"
        self.deadline = time.monotonic() + options.lifetime
        self.log = (self.root / "provision.log").open("wb")
        self.password = options.password_file.read_bytes().rstrip(b"\r\n")
        if not self.password or any(value in self.password for value in (b"\r", b"\n", b"\0")):
            raise ValueError("The fixture password must be a nonempty single line")

    def docker(self, *arguments, input=None, timeout=30):
        result = subprocess.run(["docker", *arguments], input=input, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
        # These operations never print stdin. Keep even nonsecret Docker output
        # in the private local log, avoiding accidental command/log expansion.
        self.log.write(result.stderr)
        self.log.flush()
        if result.returncode:
            raise RuntimeError("Docker " + arguments[0] + " failed; inspect " + str(self.root / "provision.log"))
        return result.stdout

    def build(self):
        build = self.root / "build"
        build.mkdir()
        (build / "Dockerfile").write_text("""FROM debian:bookworm-slim
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends openssh-server sudo ca-certificates procps \\
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /etc/ssh/ssh_host_* \\
    && useradd --create-home --shell /bin/bash itermux_test && mkdir -p /run/sshd
COPY sshd_config /etc/ssh/sshd_config
COPY sudoers /etc/sudoers.d/roamtty-fixture
RUN chmod 0440 /etc/sudoers.d/roamtty-fixture && visudo -cf /etc/sudoers.d/roamtty-fixture \\
    && ! command -v tmux && ! command -v mosh-server
""")
        # No Subsystem declaration on the normal host: this is a genuine
        # SSH-only server, exercising production shell-based launch fallback.
        (build / "sshd_config").write_text("""Port 22
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
AllowUsers itermux_test
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
PrintLastLog no
LogLevel ERROR
""")
        (build / "sudoers").write_text("Defaults:itermux_test timestamp_timeout=0\nitermux_test ALL=(ALL:ALL) ALL\n")
        print("Building an owned Debian image with real OpenSSH and sudo; no plugins or credentials are baked in.", flush=True)
        process = subprocess.Popen(["docker", "build", "--label", LABEL + "=" + self.run_id,
                                    "--tag", self.image, str(build)], stdout=self.log, stderr=self.log)
        try:
            if process.wait(timeout=min(600, self.options.lifetime)):
                raise RuntimeError("Image build failed; inspect " + str(self.root / "provision.log"))
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def start_container(self, name, port, cancellation):
        seconds = max(1, int(self.deadline - time.monotonic()))
        self.containers.append(name)
        self.docker("run", "--detach", "--rm", "--init", "--name", name, "--label", LABEL + "=" + self.run_id,
                    "--publish", f"{self.options.bind}:{port}:22", "--memory", "512m", "--cpus", "1",
                    "--pids-limit", "256", self.image, "/bin/sleep", str(seconds))
        self.docker("exec", "--interactive", name, "/usr/sbin/chpasswd", input=b"itermux_test:" + self.password + b"\n")
        self.docker("exec", name, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", "/etc/ssh/ssh_host_ed25519_key")
        if cancellation:
            self.docker("exec", "--interactive", name, "/bin/sh", "-c", "cat > /etc/apt/apt.conf.d/99-roamtty-fixture",
                        input=b'Acquire::http::Dl-Limit "16";\nAcquire::https::Dl-Limit "16";\n')
            self.docker("exec", "--interactive", name, "/bin/sh", "-c", "cat >> /etc/ssh/sshd_config",
                        input=b"Subsystem sftp internal-sftp\n")
        self.docker("exec", name, "/usr/sbin/sshd", "-t")
        self.docker("exec", "--detach", name, "/usr/sbin/sshd", "-D", "-e")
        public = self.docker("exec", name, "cat", "/etc/ssh/ssh_host_ed25519_key.pub").decode().split()
        fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(public[1])).digest()).decode().rstrip("=")
        until = time.monotonic() + 10
        while True:
            try:
                with socket.create_connection((self.options.bind, port), timeout=2) as stream:
                    if stream.recv(1024).startswith(b"SSH-2.0-"):
                        break
            except OSError:
                pass
            if time.monotonic() >= until:
                raise RuntimeError("Owned SSH fixture did not become ready")
            time.sleep(0.1)
        self.verify(name, port, public, cancellation)
        return fingerprint

    def verify(self, name, port, public, cancellation):
        # Verify the real privilege boundary without installing either plugin.
        unprivileged = "test \"$(id -u)\" != 0 && ! command -v tmux && ! command -v mosh-server && ! sudo -n true 2>/dev/null"
        self.docker("exec", "--user", "itermux_test", name, "/bin/sh", "-c", unprivileged)
        root_uid = self.docker("exec", "--interactive", "--user", "itermux_test", name,
                               "sudo", "-S", "-k", "-p", "", "id", "-u", input=self.password + b"\n").strip()
        if root_uid != b"0":
            raise RuntimeError("Container-only password sudo did not grant its intended privilege")

        known = self.root / (name + ".known_hosts")
        known.write_text(f"[{self.options.bind}]:{port} {public[0]} {public[1]}\n")
        askpass = self.root / "askpass"
        askpass.write_text("#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\nsys.stdout.buffer.write(Path(os.environ['ROAMTTY_PLUGIN_PASSWORD_FILE']).read_bytes().rstrip(b'\\r\\n') + b'\\n')\n")
        askpass.chmod(0o700)
        environment = os.environ.copy()
        environment.update({"SSH_ASKPASS": str(askpass), "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":roamtty-fixture",
                            "ROAMTTY_PLUGIN_PASSWORD_FILE": str(self.options.password_file)})
        common = ["-o", "BatchMode=no", "-o", "PreferredAuthentications=keyboard-interactive", "-o", "PasswordAuthentication=no",
                  "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=5",
                  "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + str(known)]
        target = "itermux_test@" + self.options.bind
        command = "test \"$(id -un)\" = itermux_test && ! command -v tmux && ! command -v mosh-server && printf 'INTERACTIVE_FIXTURE_OK\\n'"
        ssh = subprocess.run(["ssh", *common, "-p", str(port), target, command], env=environment,
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        if ssh.returncode or ssh.stdout.strip() != b"INTERACTIVE_FIXTURE_OK":
            raise RuntimeError("Real keyboard-interactive SSH preflight failed")
        sftp = subprocess.run(["sftp", *common, "-P", str(port), target], env=environment, input=b"quit\n",
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        if cancellation and sftp.returncode:
            raise RuntimeError("Cancellation host's real SFTP subsystem did not open")
        if not cancellation and (sftp.returncode == 0 or b"subsystem request failed" not in sftp.stderr.lower()):
            raise RuntimeError("Normal SSH-only host did not refuse the real SFTP subsystem request")
        print(f"Preflight {port}: real interactive SSH, password-only sudo, absent tmux/mosh, SFTP " + ("available" if cancellation else "refused") + ".", flush=True)

    def start(self):
        self.build()
        fingerprints = []
        for cancellation, port in [(False, self.options.port), (True, self.options.cancel_port)]:
            name = "roamtty-plugin-" + self.run_id + ("-cancel" if cancellation else "-normal")
            fingerprints.append(self.start_container(name, port, cancellation))
        environment = {"ROAMTTY_PLUGIN_HOST": self.options.bind, "ROAMTTY_PLUGIN_PORT": str(self.options.port),
                       "ROAMTTY_PLUGIN_CANCEL_PORT": str(self.options.cancel_port), "ROAMTTY_PLUGIN_FINGERPRINT": fingerprints[0],
                       "ROAMTTY_PLUGIN_CANCEL_FINGERPRINT": fingerprints[1]}
        descriptor = os.open(self.environment_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(environment, stream)
        (self.root / "ownership.json").write_text(json.dumps({"run_id": self.run_id, "image": self.image, "containers": self.containers, "pid": os.getpid()}))
        print(f"Plugin fixture ready; PID {os.getpid()}; private environment: {self.environment_file}; expires in {max(0, int(self.deadline - time.monotonic()))}s.", flush=True)

    def close(self):
        for name in reversed(self.containers):
            check = subprocess.run(["docker", "inspect", "--format", '{{index .Config.Labels "' + LABEL + '"}}', name],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
            if check.returncode == 0 and check.stdout.decode().strip() == self.run_id:
                subprocess.run(["docker", "rm", "--force", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        check = subprocess.run(["docker", "image", "inspect", "--format", '{{index .Config.Labels "' + LABEL + '"}}', self.image],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        if check.returncode == 0 and check.stdout.decode().strip() == self.run_id:
            subprocess.run(["docker", "image", "rm", self.image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        self.environment_file.unlink(missing_ok=True)
        self.log.close()
        print("Owned plugin fixture stopped; its containers and image tag were removed.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=23015)
    parser.add_argument("--cancel-port", type=int, default=23016)
    parser.add_argument("--lifetime", type=int, default=7200)
    parser.add_argument("--password-file", type=Path, default=Path(__file__).resolve().parents[2] / "roamtty" / ".private" / "test-password")
    options = parser.parse_args()
    if not 60 <= options.lifetime <= 7200 or not 1024 <= options.port <= 65535 or not 1024 <= options.cancel_port <= 65535 or options.port == options.cancel_port:
        parser.error("Use distinct unprivileged ports and a lifetime between 60 and 7200 seconds")
    if any(shutil.which(name) is None for name in ("docker", "ssh", "sftp")):
        parser.error("Docker and OpenSSH clients must already be installed")
    for port in (options.port, options.cancel_port):
        with socket.socket() as stream:
            stream.bind((options.bind, port))
    fixture = Fixture(options)

    def stop(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        fixture.start()
        while time.monotonic() < fixture.deadline:
            time.sleep(max(0, min(1, fixture.deadline - time.monotonic())))
    except KeyboardInterrupt:
        pass
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
