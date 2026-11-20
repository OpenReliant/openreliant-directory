"""Check directory-issued credentials with a real local coturn service."""
import pathlib
import runpy
import subprocess
import sys
import tempfile
import time
import uuid

helpers = runpy.run_path(str(pathlib.Path(__file__).with_name("check-directory.py")))
Host, service, request = (helpers[name] for name in ("Host", "service", "request"))
IMAGE = "coturn/coturn:4.19"
SECRET = "test-secret-only-0123456789-abcdef"


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, text=True, **kwargs)


def main(binary):
    container = "directory-relay-test-" + uuid.uuid4().hex[:12]
    try:
        docker("run", "-d", "--network", "none", "--name", container, "--entrypoint", "turnserver", IMAGE,
               "-n", "--log-file=stdout", "--no-tls", "--no-tcp-relay", "--listening-ip=127.0.0.1",
               "--relay-ip=127.0.0.1", "--allow-loopback-peers", "--use-auth-secret",
               "--static-auth-secret=" + SECRET, "--realm=example.test", "--min-port=49160",
               "--max-port=49200", "--total-quota=8", "--user-quota=4", "--relay-threads=1",
               stdout=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while True:
            result = subprocess.run(["docker", "exec", container, "turnutils_stunclient", "-p", "3478", "127.0.0.1"],
                                    capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and "reflexive addr" in result.stdout:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("STUN did not answer: " + result.stdout + result.stderr)
            time.sleep(0.2)
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            host = Host(folder)
            secret_file = folder / "turn.secret"
            secret_file.write_text(SECRET)
            with service(binary, "--stun", "stun:localhost:3478", "--turn", "turn:localhost:3478",
                         "--turn-host", host.public, "--turn-secret-file", str(secret_file)) as port:
                proof = host.proof(port, "1" * 32, "credentials", b"")
                credentials = request(port, "/v1/credentials", b"", proof)
                result = docker("exec", container, "turnutils_uclient", "-y", "-c", "-n", "3", "-u",
                                credentials["username"], "-w", credentials["password"], "127.0.0.1",
                                capture_output=True, timeout=30)
                if "tot_recv_msgs=6" not in result.stdout:
                    raise RuntimeError("TURN did not relay all test packets")
        print("STUN returned a mapped address and TURN relayed six packets with directory credentials.")
    finally:
        subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)


if __name__ == "__main__":
    main(str(pathlib.Path(sys.argv[1]).resolve()))
