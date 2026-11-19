# Hosting, joining and operating a directory

## Who runs what

An instance can offer four capabilities. Clients and hosts must be able to learn which ones an instance offers.

| Capability | What it does | Proposed default |
|---|---|---|
| Directory | Accepts public game advertisements and lets clients browse them | Enabled |
| Rendezvous | Passes connection information between a host and a joining player | Enabled |
| STUN | Reports the public IP address and port seen by that endpoint | Optional |
| TURN | Relays encrypted game traffic when a direct route fails | Disabled until the operator configures access and bandwidth limits |

Each instance chooses which games and hosts it accepts. No central directory grants permission to run another instance. Servers advertise directly to the directories they choose. Directories can operate independently without synchronising their databases or sharing accounts, signing keys, moderation or relay allowances.

A single documented deployment should support a directory, rendezvous and optional STUN and TURN on the same machine. Reuse an established STUN/TURN implementation. Operators who already run a private relay can keep using it. STUN tells a peer about its address. The directory handles game discovery, rendezvous exchanges ICE information, and TURN carries game packets only for connections that use it. See the [STUN](https://www.rfc-editor.org/rfc/rfc8489.html), [ICE](https://www.rfc-editor.org/rfc/rfc8445.html) and [TURN](https://www.rfc-editor.org/rfc/rfc8656.html) specifications.

## Hosting a game

A graphical host starts a game, picks the mode and rules, and flies as a pilot. Their process owns the simulation. The proposed default is for the session to end when the host quits. A dedicated operator starts `openreliant --headless`. That process owns the same simulation and can keep running when the last player leaves. Discovery uses the same advertisement for both.

Public advertising is opt-in. A headed host chooses whether to list the game. A dedicated operator makes the same choice in the server INI. The following illustrates the proposed settings. The addresses are examples.

```ini
[Server]
Name=Freelancer Treff Berlin
Description=German-speaking co-op on Friday evenings. New pilots welcome.
Port=27020

[Discovery]
Advertise=true
Directories=https://directory.example, https://spiele.example
```

The name appears in the list and the description in the server details. Both are plain text. Require a name for public advertising. The description is optional. Operators set them once for all their directories. Editing either updates the listing and preserves its identity. No hostname is required for the game server. Automatic server identity is the normal setup, with operator-managed credentials available as an option.

The host reports registration success or failure for each directory. Failure at one instance does not delay the match or prevent registration at another. Disabling public advertising removes existing listings. An unlisted host can still accept direct connections or explicitly use private rendezvous for an invite. A LAN-only host can run with no internet services configured.

## Finding and joining a game

Clients and hosts configure their directory lists independently. The game can ship a short, replaceable list of consenting operators, starting with the project instance. A group can add its own URL, disable a default, or use only its own directory.

| Player action | Expected behaviour |
|---|---|
| Enter an IP address or hostname | Connect to the reachable game endpoint using the default port unless a port was supplied. Joining requires no directory permission, certificate file or fingerprint prompt. |
| Select a public game | Browse enabled directories for the active game. Show each session once. Join the selected game by a direct route where available. Use its live rendezvous sources when needed. |
| Open an invite | Use the endpoint or rendezvous information in the invite. Check the expected host identity. Report an identity mismatch to the player. Private rendezvous lets the host invite friends without publishing the game. |
| Play on a LAN | Use local discovery or enter the LAN address. Both work offline. |

A direct address identifies the endpoint the player chose. An invite can additionally identify a specific server. An address invite with a persistent server key can work again after restart. A rendezvous reference for an individual session lasts only while that session is available. A password-protected game applies its password check regardless of how the player found it.

Quick join selects from compatible, joinable games with free slots across the enabled directories. Use measured latency to the game where available. A directory's location or response time does not measure a player's latency to a game. The host makes the final admission decision, including version, password, capacity and content checks.

## Reaching a host behind NAT

1. The host opens an outbound rendezvous connection to each service it intends to use. Public advertising and private invite rendezvous have separate visibility.
2. The client chooses a live source for the session. The service introduces the pair and forwards their ICE connection information. An unlisted invite supplies the rendezvous reference privately.
3. The peers try direct UDP. Use the game's configurable STUN endpoints for address discovery. A directory that offers STUN can be one of them.
4. If a direct path fails and the operator has authorised relay use, the peers can use TURN. Relay credentials are short-lived and delivered privately. A public listing grants no relay bandwidth.
5. The game verifies the connection as appropriate for the chosen join method and admits the player. Normal joining uses one gameplay connection per pilot. The host can validate controls and run the match without contacting a directory on each tick.

## What happens when a service goes away

| Failure | What the player or operator sees |
|---|---|
| One directory is slow or offline | Other directories can supply results immediately. Valid listings from them remain available. The host retries the failed registration with backoff. |
| All directories are offline | Public search reports the unavailable sources. LAN and reachable direct endpoints still work. Rendezvous-only invites need a working rendezvous source. |
| The chosen rendezvous service fails before joining | Try another configured source for the same session if one is available. Otherwise the introduction fails. |
| A directory or rendezvous service stops during a direct match | The match continues. Gameplay already travels between host and pilots. |
| The relay carrying a match stops | That route is lost. Peers need a working replacement route or a reconnect. |
| A host stops responding | Its listing expires independently at each directory. If it shuts down cleanly, it withdraws its listings immediately where possible. |

## Running a community instance

Provide one documented configuration for the public HTTPS endpoint, enabled roles, accepted games and hosts, relay authorisation, and resource limits. A German instance might list every German-speaking community server but relay only for approved hosts. A clan instance can restrict who advertises at all. An operator's decisions apply to their instance.

Live listings, leases and pending introductions may live in memory. Keep configured operator policy and service credentials across restarts. Hosts register again after a directory restart. Operators should be able to enable Prometheus metrics on a separate management port for active listings, requests, rejected registrations, introductions, and relay usage. Keep private invite references, passwords, relay credentials and players' connection details out of public listings and metrics.
