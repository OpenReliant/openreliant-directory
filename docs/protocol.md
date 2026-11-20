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
| Register | Check the host's proof of possession and the instance's advertising policy. Accept a bounded advertisement and return a lease with its expiry and renewal interval. Repeating a registration for the same verified host and session produces one listing. |
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
   disable Join and exclude them from quick join. Compare the advertised `protocol` with the
   client's gameplay protocol revision. Different releases can be compatible when they share
   that revision and pass the game's content checks.
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
| `GET /v1/capabilities` | Empty | JSON with `version` and booleans `listings`, `rendezvous`, `stun`, `turn` |
| `GET /v1/listings?game=ID` | Add `&cursor=N` from the previous page if present | JSON with `listings` and a nullable `next` cursor |
| `POST /v1/challenge` | JSON with `key`, `session` and `operation` | JSON with `challenge` and `expires_in_seconds` |
| `POST /v1/register` | Signed advertisement | JSON with `expires_in_seconds` and `renew_after_seconds` |
| `POST /v1/renew` | Signed advertisement for a live lease | Same fields as register |
| `POST /v1/withdraw` | Signed empty body | 204 |

Send POST requests with an exact `Content-Length`. The service accepts up to 4 KiB of body
and 8 KiB of headers. All keys, session IDs, challenges and signatures use lowercase hex
without punctuation. The host public key is a 32-byte Ed25519 key. The session ID is 16 bytes
selected by the host and scoped to this hosted session. The directory supplies a 32-byte
challenge tied to that host, session, operation, directory instance and observed IP address.
A challenge expires after 30 seconds and is used once.

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
summaries to 256. Addresses are built from the observed public IP and the signed UDP port.

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
503 for full service state. Request a fresh challenge when retrying a signed operation.
The service does not use the optional rendezvous or relay capabilities in this batch.
