# OpenReliant Directory

OpenReliant Directory is the design for a community-run multiplayer game directory. A player can find a public game, see whether it has room, and join it. A directory can also introduce peers for NAT traversal and offer an optional STUN endpoint or TURN relay. This repository currently contains the design. The service and game integration are planned.

The OpenReliant project can run a public instance. Groups, organisations, regions and other games can run their own. For example, a German community could list German-speaking games and reserve its relay bandwidth for community hosts. A game can advertise to both the project directory and the German directory. A player browsing both sees one game.

## Design

- [Hosting, joining and operating a directory](docs/service-design.md) describes the player and operator experience, configuration, routes and failure behaviour.
- [Directory protocol and implementation plan](docs/protocol.md) describes game advertisements, host identity, deduplication, compatibility, public-service boundaries and acceptance tests.

OpenReliant owns the game host, browser and gameplay connection. This repository owns the service, its protocol and its deployment. The directory design supports both a graphical host who plays and a dedicated headless host. Joining a reachable game by address works independently of the service.

The game-side work is tracked in [public discovery and quick join](https://github.com/OpenReliant/openreliant/issues/957) and [NAT traversal](https://github.com/OpenReliant/openreliant/issues/363). The [2.0 engine roadmap](https://github.com/OpenReliant/openreliant/issues/950) explains why StarLancer is one game among many.
