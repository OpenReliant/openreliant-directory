# OpenReliant Directory

OpenReliant Directory is the design for a community-run multiplayer game directory. A player can find a public game, see whether it has room, and join it. A directory can also introduce peers for NAT traversal and offer an optional STUN endpoint or TURN relay. The Zig service implements the listings protocol. OpenReliant browser and host integration are tracked in [#957](https://github.com/OpenReliant/openreliant/issues/957).

The OpenReliant project can run a public instance. Groups, organisations, regions and other games can run their own. For example, a German community could list German-speaking games and reserve its relay bandwidth for community hosts. A game can advertise to both the project directory and the German directory. A player browsing both sees one game.

## Design

- [Hosting, joining and operating a directory](docs/service-design.md) describes the player and operator experience, configuration, routes and failure behaviour.
- [Directory protocol and implementation plan](docs/protocol.md) describes game advertisements, host identity, deduplication, compatibility, public-service boundaries and acceptance tests.

OpenReliant owns the game host, browser and gameplay connection. This repository owns the service, its protocol and its deployment. The directory design supports both a graphical host who plays and a dedicated headless host. Joining a reachable game by address works independently of the service.

The game-side work is tracked in [public discovery and quick join](https://github.com/OpenReliant/openreliant/issues/957) and [NAT traversal](https://github.com/OpenReliant/openreliant/issues/363). The [2.0 engine roadmap](https://github.com/OpenReliant/openreliant/issues/950) explains why StarLancer is one game among many.


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
For example, an nginx location can use these settings.

```nginx
location / {
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_pass http://127.0.0.1:8080;
}
```

Use `--bind` to change the listener and `--allow-game` or `--allow-host` if the instance
lists one game or one host key. Listings are held in memory. Hosts re-register after a restart.

Release Please publishes Linux x86_64 and AArch64 archives and a single multi-architecture
image at `ghcr.io/openreliant/openreliant-directory`. On a Linux host with a local HTTPS proxy,
run the image with a loopback backend.

```sh
docker run --rm --network host ghcr.io/openreliant/openreliant-directory:latest \
  --bind 127.0.0.1:8080 --trust-proxy
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build and integration checks.
