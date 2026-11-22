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
                assert capabilities["listings"] and capabilities["rendezvous"] == ("--no-rendezvous" not in options)
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


def signal(data):
    return base64.b64encode(data).decode()


def post(port, path, body, expected=200, source=PUBLISHER, token=None):
    headers = {"X-Directory-Rendezvous": token} if token is not None else None
    return request(port, path, json.dumps(body).encode() if not isinstance(body, bytes) else body, headers, expected, source)


def check_rendezvous(binary, host, ad, sessions):
    """A host and a joining player pass signals through their exchange, and nobody else can."""
    first, second = sessions
    offer, send, poll = (f"/v1/rendezvous/{action}" for action in ("offer", "send", "poll"))
    listed = {**ad, "hosting": "player_hosted", "rendezvous": True}
    joiner = "9.9.9.9"
    with service(binary) as port:
        lease = host.publish(port, first, "register", listed)
        token = lease["rendezvous_token"]
        assert len(token) == 64 and listings(port)[0]["advertisement"]["rendezvous"] is True
        # A renewal and an update keep the token.
        assert host.publish(port, first, "renew", listed)["rendezvous_token"] == token
        assert host.publish(port, first, "renew", {**listed, "revision": 2, "players": 1})["rendezvous_token"] == token
        listed = {**listed, "revision": 2, "players": 1}
        target = {"key": host.public, "session": first}

        # The exchange: an offer, the host's poll, an answer, the player's poll. Each signal is read once.
        exchange = post(port, offer, {**target, "signal": signal(b"offer")}, source=joiner)
        assert len(exchange["id"]) == 32 and exchange["expires_in_seconds"] == 60
        post(port, send, {"id": exchange["id"], "signal": signal(b"more")}, 204, joiner)
        waiting = post(port, poll, {}, token=token)["exchanges"]
        assert waiting == [{"id": exchange["id"], "signals": [signal(b"offer"), signal(b"more")]}], waiting
        assert post(port, poll, {}, token=token) == {"exchanges": []}
        post(port, send, {"id": exchange["id"], "signal": signal(b"answer")}, 204, token=token)
        assert post(port, poll, {"id": exchange["id"]}, source=joiner) == {"signals": [signal(b"answer")]}
        assert post(port, poll, {"id": exchange["id"]}, source=joiner) == {"signals": []}

        # Tokens and ids: wrong, malformed, someone else's, or missing.
        post(port, poll, {}, 401, token="00" * 32)
        post(port, poll, {}, 401, token="not-a-token")
        post(port, poll, {}, 400)
        post(port, poll, {"id": "00" * 16}, 404, joiner)
        post(port, poll, {"id": "short"}, 400, joiner)
        post(port, poll, {"id": exchange["id"]}, 400, token=token)
        post(port, send, {"id": "00" * 16, "signal": signal(b"x")}, 404, joiner)
        post(port, send, {"id": exchange["id"], "signal": signal(b"x")}, 401, token="11" * 32)
        with tempfile.TemporaryDirectory() as other_folder:
            other = Host(Path(other_folder))
            theirs = other.publish(port, second, "register", listed, source="7.7.7.7")["rendezvous_token"]
            # Another listed host can't write into this exchange, and doesn't see it.
            post(port, send, {"id": exchange["id"], "signal": signal(b"x")}, 404, token=theirs)
            assert post(port, poll, {}, token=theirs) == {"exchanges": []}
            other.publish(port, second, "withdraw", None, expected=204, source="7.7.7.7")
            post(port, poll, {}, 401, token=theirs)

        # Malformed and oversized requests.
        post(port, offer, {**target, "signal": signal(b"x" * 2881)}, 400, joiner)
        post(port, offer, {**target, "signal": ""}, 400, joiner)
        post(port, offer, {**target, "signal": "not base64!"}, 400, joiner)
        post(port, offer, target, 400, joiner)
        post(port, offer, {**target, "signal": signal(b"x"), "extra": 1}, 400, joiner)
        post(port, offer, {**target, "signal": signal(b"x")}, 400, joiner, token=token)
        post(port, offer, {"key": host.public, "session": second, "signal": signal(b"x")}, 404, joiner)
        post(port, offer, {"key": "zz", "session": first, "signal": signal(b"x")}, 400, joiner)
        post(port, offer, b"{" + b" " * 5000 + b"}", 413, joiner)
        post(port, offer, b"not json", 400, joiner)
        post(port, "/v1/rendezvous/other", {}, 404, joiner)
        request(port, poll, expected=404, source=joiner)

        # A mailbox holds eight signals. The ninth is refused until the reader takes some.
        for _ in range(8):
            post(port, send, {"id": exchange["id"], "signal": signal(b"y")}, 204, joiner)
        post(port, send, {"id": exchange["id"], "signal": signal(b"y")}, 429, joiner)
        assert len(post(port, poll, {}, token=token)["exchanges"][0]["signals"]) == 8
        post(port, send, {"id": exchange["id"], "signal": signal(b"y")}, 204, joiner)

        # One source opens four exchanges at most.
        for _ in range(3):
            post(port, offer, {**target, "signal": signal(b"x")}, source=joiner)
        post(port, offer, {**target, "signal": signal(b"x")}, 429, joiner)
        # A listing at its eight gives up its oldest, so offers nobody follows up keep no player out.
        ids = [post(port, offer, {**target, "signal": signal(b"x")}, source=f"6.6.6.{n}")["id"] for n in range(8)]
        post(port, send, {"id": exchange["id"], "signal": signal(b"x")}, 404, joiner)
        post(port, send, {"id": ids[-1], "signal": signal(b"x")}, 204, "6.6.6.7")
        # One source makes twelve offers a minute, however fast its exchanges are pushed out.
        results = []
        for n in range(16):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            connection.request("POST", offer, json.dumps({**target, "signal": signal(b"x")}), {"X-Forwarded-For": "5.5.5.5"})
            results.append(connection.getresponse().status)
            connection.close()
        assert results.count(200) <= 12 and 429 in results, results

        # Polling has an allowance of its own, which runs out too.
        statuses = set()
        for _ in range(610):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            connection.request("POST", poll, json.dumps({"id": "00" * 16}), {"X-Forwarded-For": "4.4.4.4"})
            statuses.add(connection.getresponse().status)
            connection.close()
        assert statuses == {404, 429}, statuses
        assert listings(port), "browsing shares no allowance with signalling"

        # A new session ends the old one's exchanges and token, and so does a withdrawal.
        live = post(port, offer, {**target, "signal": signal(b"x")}, source="3.3.3.3")["id"]
        renewed = host.publish(port, second, "register", listed)["rendezvous_token"]
        assert renewed != token
        post(port, poll, {}, 401, token=token)
        post(port, send, {"id": live, "signal": signal(b"x")}, 404, "3.3.3.3")
        live = post(port, offer, {"key": host.public, "session": second, "signal": signal(b"x")}, source="3.3.3.3")["id"]
        host.publish(port, second, "withdraw", None, expected=204)
        post(port, send, {"id": live, "signal": signal(b"x")}, 404, "3.3.3.3")
        post(port, poll, {}, 401, token=renewed)
        post(port, offer, {"key": host.public, "session": second, "signal": signal(b"x")}, 404, "3.3.3.3")

    # An instance without rendezvous lists the game, gives no token and has no routes for it.
    with service(binary, "--no-rendezvous") as port:
        lease = host.publish(port, first, "register", listed)
        assert "rendezvous_token" not in lease, lease
        post(port, offer, {**target, "signal": signal(b"x")}, 404, joiner)
        host.publish(port, first, "withdraw", None, expected=204)


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

                # A restart replaces the old session even when its revision starts at one.
                host.publish(a, second, "register", {**ad, "protocol": 29, "description": "Restarted"})
                replacement, = listings(a)
                assert replacement["session"] == second
                assert replacement["advertisement"]["description"] == "Restarted"
                host.publish(a, first, "renew", updated, expected=404)
                host.publish(a, first, "withdraw", None, expected=204)
                assert listings(a)[0]["session"] == second
                assert listings(b)[0]["session"] == first

                with tempfile.TemporaryDirectory() as another_directory:
                    another = Host(Path(another_directory))
                    other = {**ad, "game": {"id": "org.example.second-game", "name": "Second Game"},
                             "mode": {"id": "flag-run", "name": "Flag Run"}}
                    another.publish(a, third, "register", other)
                    assert listings(a, "org.example.second-game")[0]["advertisement"]["mode"]["id"] == "flag-run"
                    another.publish(a, third, "withdraw", None, expected=204)
                host.publish(a, second, "withdraw", None, expected=204)
                assert not listings(a)
                assert len(listings(b)) == 1

            assert not listings(a)
            request(a, "/v1/challenge", b"{}", expected=403, source="127.0.0.1")
            # A host on a public address names another one only when the operator allows its key.
            elsewhere = {**ad, "address": "1.1.1.1"}
            host.publish(a, first, "register", elsewhere, expected=403)
            host.publish(a, first, "register", {**ad, "address": PUBLISHER})
            host.publish(a, first, "withdraw", None, expected=204)
        with service(binary, "--address-host", host.public) as named:
            host.publish(named, first, "register", elsewhere)
            assert listings(named)[0]["address"] == "1.1.1.1:27020"
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
        check_rendezvous(binary, host, ad, (first, second))
    print("Two directories kept independent leases, updates, games and withdrawals.")
    print("Rendezvous passed signals between a host and a player, and refused everyone else.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
