# OpenReliant Directory

OpenReliant Directory is a community-run service for public multiplayer game listings. Game
hosts can register, renew and withdraw signed listings. Browsers can look up a game's sessions
and see each server's name, player count, address and gameplay protocol revision. The listings
API supports any game that implements the directory protocol.

A group, organisation or region can run its own directory. Hosts can register with several
instances independently. For example, a German community can run a directory for German-speaking
games. OpenReliant's host advertising and server browser, including merging results and marking
incompatible servers, are tracked in [#957](https://github.com/OpenReliant/openreliant/issues/957).
Rendezvous is planned. An operator can add STUN and an authorised TURN relay using coturn.
The capabilities endpoint reports which features the operator configured.

## Design

- [Hosting, joining and operating a directory](docs/service-design.md) describes the player and operator experience, configuration, routes and failure behaviour.
- [Directory protocol and implementation plan](docs/protocol.md) describes game advertisements, host identity, deduplication, compatibility, public-service boundaries and acceptance tests.

OpenReliant owns the game host, browser and gameplay connection. This repository owns the service, its protocol and its deployment. The directory design supports both a graphical host who plays and a dedicated headless host. Joining a reachable game by address works independently of the service.

See [NAT traversal](https://github.com/OpenReliant/openreliant/issues/363) for the game-side connection work and the [2.0 engine roadmap](https://github.com/OpenReliant/openreliant/issues/950) for support for other games.

## Run a directory

Use Zig 0.17.1 to build and run the service locally.

```sh
zig build -Doptimize=ReleaseSafe
zig-out/bin/openreliant-directory
curl http://127.0.0.1:8080/v1/capabilities
```

For a public instance, put an HTTPS reverse proxy in front of the loopback listener and add
`--trust-proxy`. Configure the proxy to overwrite `X-Forwarded-For` with the original client
IP. Do not append to an incoming value. Keep the backend port available only to the proxy.
Publishing the backend directly exposes an unencrypted, unauthenticated HTTP endpoint.
The service accepts eight concurrent connections by default. `--max-connections` changes
the limit up to 1024. Configure connection limits at the proxy for public deployments.

Some hosting providers route requests through private addresses even for public servers.
With a trusted proxy, `--allow-private-publishers` accepts those publishers when their signed
advertisement supplies a public game IP. The proxy must supply the real client address.
For example, an nginx location can use these settings.

```nginx
location / {
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_pass http://127.0.0.1:8080;
}
```

Use `--bind` to change the listener and `--allow-game` or `--allow-host` if the instance
lists one game or one host key. Listings are held in memory. Hosts re-register after a restart.

The service logs its version at startup. Run `openreliant-directory --version` to print it.
Development builds from tagged Git history include the commit and any working tree changes
in the version string.
On startup the service checks GitHub for a newer stable release in the background and logs a
warning with the release link when one is available. The check has a five-second limit.
Use `--no-update-check` to disable it, including for an offline instance.

## Optional STUN and TURN

On Linux, the coturn deployment uses host networking. Open UDP port 3478 in the firewall.
Start the STUN-only service with `docker compose -f deploy/compose.yml --profile stun up -d`.
Set `--stun stun:directory.example:3478` on the directory to advertise that service.

TURN is disabled by default. To enable it, generate a secret and a coturn configuration:

```sh
umask 077
openssl rand -hex 32 > deploy/turn.secret
cp deploy/turnserver.conf.example deploy/turnserver.conf
printf 'static-auth-secret=%s\n' "$(cat deploy/turn.secret)" >> deploy/turnserver.conf
docker compose -f deploy/compose.yml --profile turn up -d
```

Stop the STUN-only profile first: TURN also answers STUN requests on the same port. Open
UDP ports 49160-49223 for relay allocations. Adjust the example's quotas and bandwidth caps
to the operator's budget. If the server is behind NAT, configure coturn's `external-ip` and
forward the same UDP ports. The example denies relaying to private and link-local networks.

Start the directory behind HTTPS with `--stun stun:directory.example:3478`,
`--turn turn:directory.example:3478`, `--turn-secret-file deploy/turn.secret` and one or
more `--turn-host` options containing authorised hosts' 64-digit Ed25519 public keys. Keep
the secret and generated configuration private. TURN credentials last ten minutes and are
only issued to a host that proves it owns an allowed key. Never expose them in listings.
The game still needs rendezvous integration to obtain and distribute these credentials.

The release workflow publishes Linux x86_64 and AArch64 archives and a single multi-architecture
image at `ghcr.io/openreliant/openreliant-directory`. On a Linux host with a local HTTPS proxy,
run the published image with a loopback backend.

```sh
docker run --rm --network host ghcr.io/openreliant/openreliant-directory:latest \
  --bind 127.0.0.1:8080 --trust-proxy
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build and integration checks.
