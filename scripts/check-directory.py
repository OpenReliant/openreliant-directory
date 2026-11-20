"""Run two directory instances locally with independent leases."""
import contextlib
import base64
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

OPENSSL = os.environ.get("OPENSSL", "openssl")
# A stand-in public source supplied by the test proxy. The test connects only to loopback.
PUBLISHER = "8.8.8.8"


def request(port, path, body=None, headers=None, expected=200, source=PUBLISHER):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET" if body is None else "POST", path, body, {
            "X-Forwarded-For": source, **(headers or {})
        })
        response = connection.getresponse()
        raw = response.read()
        assert response.status == expected, (path, response.status, raw)
        return json.loads(raw) if raw else None
    finally:
        connection.close()


@contextlib.contextmanager
def service(binary, *options):
    version = subprocess.check_output([binary, "--version"], text=True).strip().removeprefix("openreliant-directory ")
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        port = reserved.getsockname()[1]
    process = subprocess.Popen([binary, "--bind", f"127.0.0.1:{port}", "--trust-proxy", "--no-update-check", *options])
    try:
        deadline = time.monotonic() + 3
        while True:
            try:
                capabilities = request(port, "/v1/capabilities")
                assert capabilities["version"] == 1 and capabilities["service_version"] == version
                assert capabilities["listings"] and not capabilities["rendezvous"]
                for name in ("stun", "turn"):
                    endpoint = options[options.index("--" + name) + 1] if "--" + name in options else None
                    assert capabilities[name] == (endpoint is not None)
                    assert capabilities[name + "_endpoint"] == endpoint
                break
            except ConnectionRefusedError:
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(0.05)
        yield port
    finally:
        process.terminate()
        process.wait(timeout=3)


class Host:
    def __init__(self, folder):
        self.folder = folder
        self.key = folder / "test-key.pem"
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "ED25519", "-out", self.key], check=True)
        public = subprocess.check_output([OPENSSL, "pkey", "-in", self.key, "-pubout", "-outform", "DER"])
        self.public = public[-32:].hex()

    def proof(self, port, session, operation, body, source=PUBLISHER):
        data = json.dumps({"key": self.public, "session": session, "operation": operation}).encode()
        token = request(port, "/v1/challenge", data, source=source)["challenge"]
        payload = self.folder / "message"
        payload.write_bytes(f"OpenReliant Directory v1\n{operation}\n{token}\n{session}\n".encode() + body)
        signature = subprocess.check_output([OPENSSL, "pkeyutl", "-sign", "-rawin", "-inkey", self.key, "-in", payload])
        return {
            "X-Directory-Key": self.public, "X-Directory-Session": session,
            "X-Directory-Challenge": token, "X-Directory-Signature": signature.hex(),
        }

    def publish(self, port, session, operation, ad, expected=200, source=PUBLISHER):
        body = json.dumps(ad, separators=(",", ":")).encode() if ad is not None else b""
        return request(port, f"/v1/{operation}", body, self.proof(port, session, operation, body, source), expected, source)


def listings(port, game="org.openreliant.starlancer"):
    return request(port, f"/v1/listings?game={game}")["listings"]


def main(binary):
    version = subprocess.check_output([binary, "--version"], text=True).strip()
    assert version.startswith("openreliant-directory "), version
    with tempfile.TemporaryDirectory() as directory:
        host = Host(Path(directory))
        first, second, third = (f"{n:032x}" for n in (1, 2, 3))
        ad = {
            "game": {"id": "org.openreliant.starlancer", "name": "StarLancer"},
            "revision": 1, "name": "Berlin Lobby", "hosting": "dedicated",
            "players": 0, "capacity": 8, "accepting": True,
            "protocol": 28, "release": "1.1.0", "port": 27020,
        }
        with service(binary) as a:
            with service(binary) as b:
                lease = host.publish(a, first, "register", ad)
                assert lease == {"expires_in_seconds": 90, "renew_after_seconds": 30}
                host.publish(b, first, "register", ad)
                first_a, = listings(a)
                first_b, = listings(b)
                assert (first_a["key"], first_a["session"]) == (first_b["key"], first_b["session"])
                assert first_a["address"] == "8.8.8.8:27020" and first_a["reachability"] == "unverified"
                assert first_a["advertisement"]["players"] == 0 and first_a["advertisement"]["capacity"] == 8

                updated = {**ad, "revision": 2, "description": "German-speaking games", "players": 3}
                host.publish(a, first, "renew", updated)
                host.publish(a, first, "renew", updated)
                host.publish(a, first, "renew", ad, expected=409)
                assert listings(a)[0]["advertisement"]["description"] == "German-speaking games"
                assert listings(b)[0]["advertisement"]["revision"] == 1

                host.publish(a, second, "register", {**ad, "protocol": 29})
                other = {**ad, "game": {"id": "org.example.second-game", "name": "Second Game"},
                         "mode": {"id": "flag-run", "name": "Flag Run"}}
                host.publish(a, third, "register", other)
                by_session = {entry["session"]: entry["advertisement"] for entry in listings(a)}
                assert set(by_session) == {first, second}
                assert by_session[first]["protocol"] == 28 and by_session[second]["protocol"] == 29
                assert by_session[first]["release"] == by_session[second]["release"]
                assert listings(a, "org.example.second-game")[0]["advertisement"]["mode"]["id"] == "flag-run"
                host.publish(a, second, "withdraw", None, expected=204)
                assert len(listings(a)) == 1
                assert len(listings(b)) == 1

            assert listings(a)[0]["advertisement"]["revision"] == 2
            host.publish(a, first, "withdraw", None, expected=204)
            assert not listings(a)
            request(a, "/v1/challenge", b"{}", expected=403, source="127.0.0.1")
        with service(binary, "--allow-private-publishers") as private:
            internal = "10.2.3.4"
            host.publish(private, first, "register", ad, expected=403, source=internal)
            published = {**ad, "address": "1.1.1.1"}
            host.publish(private, first, "register", published, source=internal)
            assert listings(private)[0]["address"] == "1.1.1.1:27020"
            host.publish(private, first, "withdraw", None, expected=204, source=internal)
        secret = b"test-secret-only-0123456789-abcdef"
        secret_file = Path(directory) / "turn-secret"
        secret_file.write_bytes(secret)
        with service(binary, "--stun", "stun:relay.example:3478", "--turn", "turn:relay.example:3478",
                     "--turn-host", host.public, "--turn-secret-file", str(secret_file)) as relay:
            proof = host.proof(relay, first, "credentials", b"")
            invalid = {**proof, "X-Directory-Signature": "00" * 64}
            request(relay, "/v1/credentials", b"", invalid, expected=401)
            credentials = request(relay, "/v1/credentials", b"", proof)
            username = credentials["username"]
            assert int(time.time()) < credentials["expires_at"] <= int(time.time()) + 600
            assert username == f'{credentials["expires_at"]}:{host.public}'
            assert credentials["password"] == base64.b64encode(hmac.digest(secret, username.encode(), hashlib.sha1)).decode()
            request(relay, "/v1/credentials", b"", proof, expected=401)
            with tempfile.TemporaryDirectory() as other_directory:
                other = Host(Path(other_directory))
                denied = other.proof(relay, second, "credentials", b"")
                request(relay, "/v1/credentials", b"", denied, expected=403)
    print("Two directories kept independent leases, updates, games and withdrawals.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
