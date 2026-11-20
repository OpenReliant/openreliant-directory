# Contributing

Use Zig 0.17.1. Build with `zig build` and run `zig-out/bin/openreliant-directory --help`.
Python 3 and OpenSSL are needed for the HTTP smoke test.

## Code and protocol

- Keep game identifiers, names and modes as data. The service works with multiple games and
  keeps its protocol separate from the gameplay transport.
- Use ordinary Zig structs for state, tagged unions or enums for choices, and error unions
  for failures. Keep HTTP handling, proof validation and lease storage in their own modules.
- Keep request sizes, response sizes, concurrent work and stored records bounded. A network
  request must never tell the service to dial an arbitrary address.
- Update [the protocol](docs/protocol.md) and the interoperability tests together when clients
  or hosts need to change.
- Use short comments for the reason a rule exists. Use plain English and British spelling.
  Avoid em and en dashes.

## Checks

Run these before opening a pull request.

```sh
zig fmt --check build.zig build.zig.zon src
zig build test --summary all
zig build
python3 scripts/check-directory.py zig-out/bin/openreliant-directory
python3 scripts/check-relay.py zig-out/bin/openreliant-directory
```

CI also builds the Linux x86_64 and AArch64 releases. Run the service on loopback while
developing. The HTTP test runs independent instances locally. The relay test uses Docker to
run coturn on an isolated network and checks a STUN request and an authenticated TURN exchange.

## Pull requests and releases

Branch from `main`. Use a Conventional Commits title, for example
`feat: add signed leases for public listings` or `fix: expire withdrawn games promptly`.
Explain what changed, how you checked it and any remaining work. End with `Closes #N`
for each completed issue. The maintainer squash-merges pull requests.

Release Please opens a release pull request with the next version in `build.zig.zon` and
the changelog. Merging it publishes archive downloads for Linux x86_64 and AArch64 and a
single multi-architecture image at `ghcr.io/openreliant/openreliant-directory`.

GitHub makes the container package private on its first publication. Set its visibility to
Public when the image is ready for anonymous community pulls.
[GitHub Packages visibility](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
