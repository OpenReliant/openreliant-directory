# Notes for coding agents

Follow [CONTRIBUTING.md](CONTRIBUTING.md). Keep this repository focused on discovery,
rendezvous and optional relay coordination. Game rules, player admission and gameplay
traffic belong to the game host.

- **Starting an issue.** Read the issue, its comments and related closed issues first.
  Read the relevant parts of [the protocol](docs/protocol.md) before changing the wire format.
- **Trying a change.** Build with `zig build` and run the service on a loopback port.
  Use local instances for integration tests.
- **Pull requests.** Branch from main. Push the branch and open the pull request
  when the checks pass. The maintainer merges it. Wait for that merge before starting
  the next feature.
- **Attribution.** Use the maintainer's git identity alone. Leave out attribution
  trailers and generated-by footers.
- **Gaps.** Record gaps under the relevant milestone and name the issues in your reply.
- **Plain English.** Use normal word order, short sentences and British spelling.
  Avoid em and en dashes. Rewrite nearby text plainly when you change it.
