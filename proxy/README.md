# voxgig-station — the station companion proxy

The optional companion daemon of [voxgig/station](../README.md) (design
D2): the consolidated control surface for every attached station
library — registration, events, live tap — and the
credential-injecting, policy-enforcing, capturing forward hop for their
traffic. The authoritative design is
[`docs/design/station.md`](../docs/design/station.md) — principally §8
(wire protocol and proxy), §5.3 (isolation rungs / R2), §6 (events),
§14 (failure modes and error codes), §15 (security posture), §16
(policy) — plus
[`docs/design/decisions.md`](../docs/design/decisions.md)
(per-instance grants; single-team v1).

## Scope: v1 core

- **Single-team, fully mutually trusting** (§8.4, D-2026-08-24-2): the
  proof-of-token gate is the entire authn story; no per-principal
  state anywhere. A shared cross-team deployment is unsupported until
  the v2 authorization design exists.
- **In-memory stores**: sessions, the event ring, grants, and the
  capture store live in process memory. The only persisted state is
  the approval file — blessed base/hosts/name **triples, never secret
  values** — beside the token file. Secret values live in memory only
  (§8.5); sekreto providers are readers and the proxy writes no copy
  of a credential anywhere on disk.
- **Local loopback TCP only**: default `127.0.0.1:8299`.

## The security model, one screen

- **Local auth is a token file** (`~/.voxgig/station/token`, 0600 in a
  0700 directory, created by the daemon on first run). Every request
  except `GET /v1/health` requires it as a bearer token, compared in
  constant time; it is never logged.
- **The client authenticates the daemon first** (§8.1): a fixed
  loopback port can be squatted, so before anything sensitive is sent,
  a nonce on the exempt health endpoint must come back with
  `Station-Proof: hex(HMAC-SHA256(token, nonce))`. A process that
  cannot produce the proof does not hold the token file; the failure
  reads as absence (§14). Every CLI verb does this handshake too.
- **DNS-rebinding hardening**: `Host` is validated against the bound
  address's local names and any unexpected `Origin` is rejected, on
  every request including health.
- **Everything a client registers is untrusted input** (§8.3). The
  proxy loads its *own* `station.json` and derives hosts allowlists
  and instance→secret-name mappings from it alone. No first-seen
  shortcut: instances park in `pending` — capture and
  library-resolved traffic working — until an explicit
  `voxgig-station approve <ref>` blesses the base/hosts/name triple.
  A changed triple re-enters pending. A descriptor can only *narrow*
  approved policy, never widen it, and never selects a secret.
  Off-allowlist egress is `station_host_allow`.
- **R2 grants are per instance** (D-2026-08-24-1): issued at
  registration for approved `resolve: proxy` instances, session-bound,
  15m TTL, renewed only by re-registration, revoked per instance. The
  proxy resolves through its own sekreto and injects on the outbound
  hop; the application process never holds the value.
- **The upstream client never follows redirects** (§8.2): a 3xx rides
  back as metadata, so a `Location` off the allowlist cannot pull an
  automatic credentialed follow-up. No MITM, ever — the envelope keeps
  the proxy a first-party recipient, not an interceptor.
- **Redaction at capture time, never retroactively** (§15): the seeded
  header redact-list, each exchange's `Station-Redact` values (held
  transiently, discarded unwritten), and every broker-resolved value —
  exact match, no length floor — are scrubbed before an entry is
  stored. Secret bytes never enter the capture store; a `full`-depth
  exchange carrying a credential the proxy cannot scrub degrades to
  `headers` and says so in status.

## Run, approve, tap

```
$ voxgig-station run                  # daemon on 127.0.0.1:8299 (alias: serve)
$ voxgig-station status               # plugins, sessions, stores, bounds
$ voxgig-station approve solardemo    # bless a pending instance's triple
$ voxgig-station tap [plugin]         # live NDJSON event stream (ctrl-c stops)
```

`status`/`approve`/`tap` discover the daemon per §8.1 — `--url` flag,
else `VOXGIG_STATION_URL`, else `http://127.0.0.1:8299` — and read the
bearer token from `--token`, else the token file. `approve` talks only
to the running daemon: the daemon owns approval state, and when it is
down the verb says how to start it rather than forking the state.

Daemon flags (`run`): `--listen`, `--token-file`, `--config` (own
station.json; default cwd-up lookup then `~/.voxgig/station.json`),
`--profile`, `--state-file`, and one flag per bound — `--session-ttl`
`--grant-ttl` `--ring` `--capture-entries` `--capture-bytes`
`--capture-body` `--forward-body` `--events-body` `--register-body`
`--event-line` `--tap-buffer` `--poll-timeout` `--upstream-timeout`.
Every bound is visible in `GET /v1/status` (§8.5). Defaults:
ring 10k events; capture store 10k entries / 256MB; capture bodies
truncated at 64KB; forward bodies capped at 32MB.

## Wire surface (protocol 1)

All endpoints except `/v1/health` require `Station-Protocol: 1`
(§8.6: the proxy accepts versions N and N−1; v1's accepted set is
`{1}`) and the bearer token.

| endpoint | does |
|---|---|
| `GET /v1/health[?nonce=N]` | probe + proof-of-token; the single unauthenticated endpoint, returns nothing sensitive |
| `POST /v1/register` | `{descriptor, process, instance?, identity?}` → `{session, binding}`; binding carries state/capture/resolve/ttl and, when approved, hosts (narrowed), the secret *name*, and for `resolve: proxy` the grant |
| `DELETE /v1/session` | clean shutdown, idempotent (§3.4); `Station-Session` header |
| `POST /v1/events` | NDJSON batch into the bounded ring; carries session liveness; never fails an operation (§6) |
| `GET /v1/tap[?plugin=ref]` | live NDJSON stream, quiet when idle; slow consumers drop, never stall ingest |
| `POST /v1/forward` | the §8.2 data plane: JSON envelope `{url, method, headers, body}` in; raw upstream body out (chunked, binary-safe) with `Station-Status` and per-header `Station-Up-<name>` (repeats preserved); honors `Station-Session`/`Station-Plugin`/`Station-Corr`/`Station-Grant`/`Station-Redact` |
| `POST /v1/approve/{ref}` | bless the triple (the HTTP surface under the CLI verb) |
| `DELETE /v1/grants/{ref}` | revoke one instance's grants |
| `GET /v1/policy/{ref}[?version=N]` | effective policy view; with `version` a long-poll (change or 25s) |
| `GET /v1/status` | sessions/plugins with live state, ring fill, capture fill, grants, policy coverage, every bound, uptime |

Captures record `replayable`: false when the request body was
truncated or body redaction replaced bytes the request needs —
redacted *auth headers* excepted, since replay restores them through
the credential path (§8.5).

## Error shape and codes

Every error is `{"error":{"code","message"}}`, codes in §14's house
grammar. Where the shared catalog (`station/typescript/src/error.ts`,
pinned by the `errors` corpus section) covers the condition the
catalog string is used: `station_protocol`, `station_body_limit`,
`station_host_allow`, `station_grant_expired`,
`station_secret_no_value`, `station_secret_error`,
`station_config_invalid`.

**Candidate catalog codes — seven wire codes awaiting owner sign-off.**
These daemon-boundary conditions have no catalog code yet; the proxy
uses grammar-conformant strings, proposed as catalog additions. None
surfaces as a library `err.code` — per §14, auth and proof failures
read to a library exactly like proxy absence.

| candidate code | when |
|---|---|
| `station_token_allow` | bearer token missing or wrong (401) |
| `station_origin_allow` | Host/Origin validation failed (403) |
| `station_no_session` | unknown or expired session — re-register (404) |
| `station_register_invalid` | malformed `/v1/register` body (400) |
| `station_forward_invalid` | malformed `/v1/forward` envelope (400) |
| `station_upstream` | upstream unreachable / failed before a response (502) |
| `station_no_route` | unknown path or method (404/405) |

## Deferred (later phases, seams left)

- SQLite capture persistence (and its encryption-at-rest question, §18)
- replay / record / mock (`station_replay_lossy`, `station_agent_allow`
  stay unraised until then; the `replayable` flag and store snapshot
  seam are ready)
- the MCP surface (§7) and the `traffic` query endpoint over the ring
  and capture store
- streaming uploads through the envelope (§18; v1 buffers at 32MB)
- OTLP export
- unix-socket listener and remote/TLS mode (§8.4, gated on the
  multi-tenancy answer)
- config reload (config loads at startup; the long-poll versioning is
  ready to broadcast a reload when it lands)
- server-variable expansion in the §16 hosts default (base host only
  for now)

## Develop

```
make build   # go.work against the sibling sekreto checkout, then build
make test    # go test -count=1 ./...
make vet
make clean
```

The generated `go.work` points at the sibling `voxgig/sekreto`
checkout (`SEKRETO_HOME` overrides the search). The module requires
`github.com/voxgig/sekreto/go` and nothing else — the proxy holds
secrets, so it is the hardening focus and keeps a minimal dependency
surface (§15). The test suite includes `TestContract`, a sequential
walk of the whole §8 surface against one spawned daemon — read it as
the protocol narrative.
