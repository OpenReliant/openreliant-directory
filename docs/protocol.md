# Directory protocol and implementation plan

## Scope and ownership

This repository owns the directory protocol, service, deployment documentation and interoperability fixtures. OpenReliant owns hosting and advertising, the server browser, invites, gameplay admission, and the transport that carries the simulation. The directory protocol has its own major version. A directory upgrade should not require a new gameplay protocol revision.

The directory treats game, mode and scenario identifiers as data. A standalone game supplies its own identifiers and names. A total conversion can identify itself as a separate game. A mod that supplies a new mode within a game uses that game's ID and its own mode ID. The directory needs no knowledge of StarLancer's mission format or rules. See the [engine roadmap](https://github.com/OpenReliant/openreliant/issues/950) and [custom game modes](https://github.com/OpenReliant/openreliant/issues/1400).

## Advertisement

| Field | Semantics |
|---|---|
| Game ID and display name | A stable, namespaced ID supplied by the game package. The display name is for people and can change. Filter browsing by the ID. |
| Server identity | Public key identifying the host. A dedicated host keeps its private identity across restarts. The directory receives only public identity material and proof of possession. |
| Session ID | An opaque ID generated once per hosted lobby or session. The same session uses the same ID with every directory. A new independent session gets a new ID. |
| Listing revision | A host-controlled counter increasing when public metadata changes. All directories get the same revision for the same update. |
| Server name and description | A required plain-text listing name and an optional plain-text description. Neither identifies the session. |
| Hosting type | A headed player-hosted game or a dedicated headless server. |
| Mode and scenario | Game-defined IDs and display names. Omit fields that do not apply. |
| Availability | Current players, capacity, whether admission is open, and whether a password is required. |
| Compatibility | Multiplayer protocol revision, human-readable release and summary of required client content. Different engine releases may share a gameplay protocol. |
| Join routes | Public game endpoint where applicable, or the availability of rendezvous through the directory serving this record, or both. |

No player roster is required for discovery. A compatibility summary helps the browser identify candidate games. The host checks required client content, type mappings and applicable gameplay parameters during admission. Server-only rules can change without every pilot installing the host's scripts. The directory neither distributes mods nor loads game code. See [server mod compatibility](https://github.com/OpenReliant/openreliant/issues/956).

## Operations and lifetime

The following is the required behaviour. The listing operations are implemented by [HTTP listings v1](#http-listings-v1).

| Operation | Contract |
|---|---|
| Get capabilities | Return the supported directory protocol version and available directory, rendezvous, STUN and TURN capabilities. Public capability data contains no credentials. |
| Register | Check the host's proof of possession and the instance's advertising policy. Accept a bounded advertisement and return a lease with its expiry and renewal interval. A verified host has one listing per directory. Registering a new session with the same key replaces its previous listing. Renewals and withdrawals still require the current session. |
| Update or renew | Only the authorised host can change its listing. A renewal extends the lease. An older update must not overwrite a newer revision. Retrying the same revision is safe. |
| Withdraw | Remove the caller's listing from this directory. Retrying after removal is safe. Loss of the withdrawal is covered by lease expiry. |
| Browse | Return live public listings for a game ID, with bounded pages. Include the source's lease freshness and routes. Exclude expired, private and locally moderated sessions. |
| Introduce | Forward bounded signalling between the requesting client and a live host session. Private introductions require the private session reference. Do not expose private sessions through browse or lookup by public name. |
| Authorise TURN | Apply the relay operator's policy and quotas. Deliver short-lived credentials privately only for an allowed use. The game host still decides who joins the match. |

A suggested starting point is renewal every 30 seconds and expiry after 90 seconds. The directory controls its lease durations and measures elapsed time locally. Hosts honour the returned interval, spread renewals slightly and back off on errors. Renewals keep the lease alive without inventing a new metadata revision. A directory may reject advertisements for unsupported games, unapproved hosts, capacity limits or invalid input. Report failure for that source without interrupting other registrations.

## Merging results in the client

1. Query enabled directories concurrently for the active game ID. Give each source its own deadline. Display results as they arrive.
2. Group by the tuple **(game ID, server public identity, session ID)**. Keep the source and expiry of each result. An IP address or a display name cannot distinguish two sessions reliably.
3. Show the freshest applicable metadata revision. Keep routes associated with the live source that supplied them. If two sources disagree at the same revision, retain one complete record under a deterministic configured-source order. Recheck the actual game at join time.
4. Expire each source independently. Remove the row once it has no live sources. Never let cached directory data override a host's refusal at join time.
5. Keep games with a different gameplay protocol revision visible. Grey out their rows,
   disable Join and exclude them from quick join. Show `incompatible server version: x (have y)`
   when the pointer rests on a greyed-out row. Replace `x` with the advertised `protocol` and
   `y` with the client's gameplay protocol revision. Different releases can be compatible
   when they share that revision and pass the game's content checks.
6. When joining from a row, verify that the peer matches the advertised identity and intended
   session. A stale record must not silently connect the player to a different game that reused
   the address.

For example, the same Berlin game at revision 12 arrives through directories A and B. A receives revision 13 with a new description and B still has 12. The client shows the new description and one row. If B goes offline, A's route remains. If another host uses the same name, it has its own row. Quick join ranks these deduplicated games using compatibility, available places and measured game latency where available.

## Public-service boundaries

- Authenticate registration and changes to a listing. Use a fresh challenge tied to the instance and operation so a registration recorded at one directory cannot be replayed at another. Authorise renewal and withdrawal for the specific host and session. A directory controls what appears in its own list. Its claims are still checked when the player connects.
- Treat every advertisement as untrusted. Bound text, message sizes, live leases, page sizes, update rates, concurrent introductions and pending signalling. Display descriptions as text. Verify a claimed public endpoint before marking it reachable. Rendezvous-only games must be able to register without a public listening port.
- Public advertisements must not direct clients or directory probes to arbitrary local or private services. Keep LAN discovery and privately exchanged ICE candidates separate from public browser endpoints. An address reported by STUN alone is insufficient evidence that other peers can reach it.
- Keep private rendezvous references unguessable and scoped to a live host session. Keep candidate exchange confined to the participating peers. Possessing an invite does not bypass host passwords or content checks.
- TURN is opt-in and authenticated. Enforce allocation, traffic and lifetime limits. A community can stop issuing relay access while continuing to list games. Public browsing does not require a player account, and a directory outage must not prevent direct admission.

## Delivery and acceptance

| Batch | What to build | What must pass |
|---|---|---|
| 1. Listings and direct joins | Versioned discovery protocol, independent host leases, browsing and game-side deduplication | Run two directories and advertise one game to both and another to one. Update its name and description. Verify one row, correct expiry, separate sessions with the same name, and continued browsing after either instance stops. Use a second game and a custom mode without changing directory code. Join a reachable server by address with both directories offline. |
| 2. Player-hosted games and private rendezvous | Outbound host registration, signalling for public and unlisted games, invite integration | Browse and join a headed game. Invite a friend to an unlisted one without exposing it through public search. Demonstrate a direct ICE game across two independently routed networks. Stop rendezvous after connection and finish the match. Check failure and retry through a second source. |
| 3. Community STUN and TURN | Documented optional deployment, restricted relay credentials, quotas and operator metrics | Run a regional instance with STUN and TURN. Verify direct traffic stays direct when possible, an authorised pair completes a relayed match on networks requiring it, and an unauthorised host cannot use the relay. Exercise exhausted quotas and loss of the active relay. |

The existing transport probe demonstrated a two-site TURN route. A successful direct-only game across two independently routed networks is still an acceptance test. The [route evidence](https://github.com/OpenReliant/openreliant/issues/1404) records the distinction. Keep the real headless simulation and the same game admission checks in the game-side tests.

## Decisions before implementation

The approved architecture supports independent instances, multiple advertisement and browse sources, game-defined IDs, and optional STUN and TURN. Before implementing each relevant batch, record the following details here and add test fixtures for decisions that affect interoperability.

- **Listings:** exact wire schema, identity proof and lease format, game-ID naming convention, size and rate limits, and protocol-version negotiation.
- **Rendezvous:** signalling framing, private invite encoding, expiry and retry rules. Existing direct-IP invites with a persistent server key should remain usable after a server restart.
- **Deployment:** implementation language and packaging, HTTPS setup, choice of STUN/TURN package, relay credential integration and management-port defaults.
- **Game integration:** final INI spelling, browser integration and the consenting directory URLs shipped by default. The discovery design does not require a change to the existing public modding API.

Related game-side work is tracked in [public game discovery](https://github.com/OpenReliant/openreliant/issues/957), [NAT traversal](https://github.com/OpenReliant/openreliant/issues/363) and [dedicated hosting](https://github.com/OpenReliant/openreliant/issues/364).


## HTTP listings v1

Run public deployments over HTTPS. Paths below are relative to the directory origin.
A client can discover capabilities or browse without an account.

| Method and path | Request | Success |
|---|---|---|
| `GET /v1/capabilities` | Empty | JSON with `version`, `service_version`, capability booleans, and nullable `stun_endpoint` and `turn_endpoint` |
| `GET /v1/listings?game=ID` | Add `&cursor=N` from the previous page if present | JSON with `listings` and a nullable `next` cursor |
| `POST /v1/challenge` | JSON with `key`, `session` and `operation` | JSON with `challenge` and `expires_in_seconds` |
| `POST /v1/register` | Signed advertisement | JSON with `expires_in_seconds` and `renew_after_seconds` |
| `POST /v1/renew` | Signed advertisement for a live lease | Same fields as register |
| `POST /v1/withdraw` | Signed empty body | 204 |
| `POST /v1/credentials` | Signed empty body from an authorised TURN host | JSON with `username`, `password` and `expires_at` |

`version` is the directory protocol version. `service_version` is the service's semantic version,
the same value printed by `--version`, including any build metadata. Clients can compare it with
their supported service version range. Ignore build metadata for semantic version precedence.
Older services do not include `service_version`; clients must handle the missing field explicitly.
STUN and TURN endpoint strings are public configuration, not credentials. Only advertise an
endpoint when its service is actually running. An authorised host obtains a challenge for the
`credentials` operation and signs an empty request as for a listing. The directory returns a
short-lived coturn REST credential over HTTPS, with an expiry in Unix seconds. The host must
deliver it privately to the joining player. A public listing does not grant relay access. The
existing per-source request limits and single-use challenges apply. The directory can authorise
up to 64 host keys. The client and rendezvous integration for distributing these credentials
are not implemented yet.

Send POST requests with an exact `Content-Length`. The service accepts up to 4 KiB of body
and 8 KiB of headers. All keys, session IDs, challenges and signatures use lowercase hex
without punctuation. The host public key is a 32-byte Ed25519 key. The session ID is 16 bytes
selected by the host and scoped to this hosted session. The directory supplies a 32-byte
challenge tied to that host, session, operation, directory instance and observed source.
A challenge expires after 30 seconds and is used once. Use it straight away: when every
challenge slot is taken, the one that has waited longest is dropped to make room.

A source is an IPv4 address or an IPv6 /64, because an IPv6 host can use any address of its
/64. The request allowance, the pending challenges and the publisher quota all count by source.
A source may send 120 requests a minute, hold 8 pending challenges and publish 16 listings.

Send the key, session, challenge and signature as `X-Directory-Key`,
`X-Directory-Session`, `X-Directory-Challenge` and `X-Directory-Signature`.
Sign these bytes with the host's Ed25519 key. Each separator is one ASCII LF.
Append the HTTP body bytes unchanged after the last LF.

```text
OpenReliant Directory v1
<operation>
<challenge>
<session>
<HTTP body>
```

An advertisement uses this shape.

```json
{
  "game": {"id": "org.openreliant.starlancer", "name": "StarLancer"},
  "revision": 1,
  "name": "Berlin Lobby",
  "description": "German-speaking co-op",
  "hosting": "dedicated",
  "mode": {"id": "cooperative", "name": "Co-op"},
  "players": 0,
  "capacity": 8,
  "accepting": true,
  "password": false,
  "protocol": 28,
  "release": "1.1.0",
  "content": "",
  "port": 27020
}
```

`hosting` also accepts `player_hosted`. `description`, `mode`, `scenario`, `password`
and `content` are optional. `scenario` uses the same shape as `mode`. IDs are 1 to
64 lowercase ASCII bytes. Internal hyphens, underscores and dots are allowed.
Use a namespaced game ID, for example `org.openreliant.starlancer`.
Names are limited to 96 UTF-8 bytes, descriptions to 512, release names to 64 and content
summaries to 256. Addresses use the observed public IP and the signed UDP port. A host
behind a provider with separate inbound and outbound addresses may set `address` to a
public IP literal in its signed advertisement. The directory does not verify that address,
and players' games ping every listed address. So a host that publishes from a public address
may only name another one when the operator has allowed its key with `--address-host`.
Otherwise the directory answers 403. Naming the address it publishes from is always allowed,
and a host that publishes from a private address has to name a public one
(`--allow-private-publishers`). Clients must verify the advertised host key when connecting.
Publisher quotas continue to use the observed source address.

A listing contains `key`, `session`, `address`, `reachability`,
`expires_in_seconds` and the original `advertisement`. Reachability is `unverified`.
A game connection must verify the advertised server identity and session before admission.
The service makes no outbound connection to an advertisement. It rejects private,
loopback and reserved publisher addresses. Leases last 90 seconds with renewal after
30 seconds. Renewals at the same revision must repeat the same body bytes and observed
endpoint. Change the revision when any metadata or the endpoint changes.

Browse pages contain at most 16 listings. Treat the cursor as opaque and start fresh on
refresh. Concurrent updates can change later pages. Errors use 400 for invalid input, 401
for a missing or invalid proof, 403 for policy, 404 for a missing lease or route, 405 for
method, 409 for stale or conflicting revisions, 413 for a large body, 429 for quota and
503 when every listing slot is taken. A flood of new sources or unused challenges never
causes a 503: the oldest entry makes room. When every listing slot is taken, the source with
the most listings gives up the one that expires first to a source that would still have
fewer afterwards. A host that loses a listing this way gets 404 on its next renewal and
registers again. Request a fresh challenge when retrying a signed operation.
The service can advertise an operator-configured STUN or TURN endpoint and issue credentials
to authorised TURN hosts. Game-side credential distribution is not implemented.

## Rendezvous

A host behind a router with no forwarded port can't be reached at its listed address. With
rendezvous, the directory passes the two sides' connection signals to each other, and the game
then connects them directly. The directory doesn't read the signals and never dials anything.
The capabilities endpoint reports `rendezvous` as true where the instance offers it. An operator
turns it off with `--no-rendezvous`.

A host asks for it with `"rendezvous": true` in its signed advertisement. Only send the field to
an instance that reports the capability, since an instance that doesn't know a field refuses the
advertisement. The answer to `register` and `renew` then carries `rendezvous_token`, 64 hex
digits. The token is the host's secret for its mailbox. It stays the same while the session is
listed, and ends with the lease, with a withdrawal, when a new session of the same host
registers, and when the host stops asking.

| Request | Body | Response |
|---|---|---|
| `POST /v1/rendezvous/offer` | `key` and `session` of a listing, and the first `signal` | `id` of the new exchange and `expires_in_seconds` |
| `POST /v1/rendezvous/send` | `id` and a `signal` | 204 |
| `POST /v1/rendezvous/poll` | A player: `id`. A host: an empty object | A player: `signals`. A host: `exchanges`, each with its `id` and `signals` |

A player sends no credentials: the exchange's `id`, 32 hex digits from the offer's answer, is its
secret. A host sends its token in `X-Directory-Rendezvous`. A signal is base64 of up to 2880
bytes. A poll returns each waiting signal once, oldest first, up to about 16 KiB an answer, and
leaves the rest for the next poll.

The game's own connection still has to check the host's key from the listing. The directory
only carries the signals, so a directory that altered them could stop a connection but could not
stand in for the host.

Limits:

- An exchange lives 60 seconds, and ends after 30 seconds without a signal or a poll.
- Eight signals wait in each direction. A ninth gets 429 until the reader takes some.
- One source holds four open exchanges and makes twelve offers a minute. More get 429.
- A listing has eight open exchanges. A ninth offer replaces its oldest one, and a full table
  of 64 drops its oldest exchange, so offers nobody follows up keep no player out.
- Rendezvous requests have an allowance of their own, 600 a minute for a source, so polling
  doesn't use up the 120 a minute that browsing and publishing share.
- Errors: 400 for a malformed request or signal, 401 for a host token that isn't a listed
  host's, 404 for an exchange or a listing that isn't there, 413 for a large body and 429 for a
  quota or a full mailbox.

A host polls every second or two while it accepts players, and both sides poll a few times a
second while a player joins.
