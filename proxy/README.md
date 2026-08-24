# voxgig-station — the station companion proxy

The optional companion daemon of [voxgig/station](../README.md) (design
D2): one Go binary that attached station libraries stream to, and the
future home of consolidated capture, proxy-boundary credential
injection, replay/mock, and the MCP agent surface. The authoritative
design is [`docs/design/station.md`](../docs/design/station.md) —
principally §8 (wire protocol and proxy), §6 (events), §14 (failure
modes and error codes), §15 (security posture) and §16 (policy).

## Scope: v1 control-plane core

This directory currently ships the **control-plane core** and nothing
more:

- **Single-team, fully mutually trusting** (§8.4, decision
  D-2026-08-24-2): the proof-of-token gate is the entire authn story;
  there is no per-principal state anywhere. A shared cross-team
  deployment is unsupported until the v2 authorization design exists.
- **In-memory stores only**: sessions and the event ring live in
  process memory; nothing is persisted (§8.5's optional SQLite capture
  store is a later phase). Secret values are never held at all — R2
  and grants have not arrived yet.
- **Local loopback TCP only**: default `127.0.0.1:8299`; the unix
  socket and remote (TLS) modes are later phases.

Later phases (clean seams left for each): `/v1/forward` (the data
plane), grants + `DELETE /v1/grants/{ref}` (R2, over the Go sekreto —
the Makefile already wires the sibling checkout into the workspace),
proxy-side policy authority and `approve` (§8.3), the capture store
with `traffic`/`replay`/`mock`, `GET /v1/policy/{ref}` long-poll, OTLP
export, and the MCP server (§7).

## Run

```
make build          # builds ./voxgig-station
./voxgig-station run
# or
make run
```

Flags for `run`:

| flag | default | design |
|---|---|---|
| `--listen` | `127.0.0.1:8299`, or `VOXGIG_STATION_URL` (the flag wins) | §8.1 |
| `--token-file` | `~/.voxgig/station/token` | §8.1 |
| `--session-ttl` | `5m` (unpinned by the design; liveness rides `/v1/events`) | §3.4 |
| `--ring` | `10000` entries | §8.5 |

On first run the daemon creates the token file (0600, inside a 0700
directory). Every request except `GET /v1/health` requires it as a
bearer token, compared in constant time. It is never logged.

## Wire surface (protocol 1)

All endpoints except `/v1/health` require `Station-Protocol: 1` and
`Authorization: Bearer <token>`. Per §8.6 the daemon accepts protocol
versions N and N−1; v1 is the first, so the accepted set is `{1}`, and
anything else is a structured `station_protocol` error. `Host` is
validated against the bound address's local names and any unexpected
`Origin` is rejected — the §8.1 DNS-rebinding hardening — on every
request, health included.

- `GET /v1/health[?nonce=N]` — the single unauthenticated endpoint.
  Returns `{ok, station, version, protocol}` (nothing sensitive). With
  a nonce, the response carries `Station-Proof:
  hex(HMAC-SHA256(token, nonce))` so a client can verify it is talking
  to the real daemon — the holder of the token file — *before* sending
  its bearer token, envelopes, or events (§8.1). A proof failure reads
  as absence (§14).
- `POST /v1/register` — `{descriptor, process: {pid, lang, app},
  identity?}` → `{session, binding}`. The descriptor is **untrusted
  input** (§8.3): stored verbatim for status and observability, and
  nothing security-relevant is derived from it. With no proxy-side
  policy authority yet, every registration parks in state
  **`pending`**; the binding reports `{state, capture, protocol,
  ttlSeconds}`, and grows base/credential-plan/policy when those
  phases land. `identity` is accepted and ignored (reserved for remote
  mode, §8.2/§8.4).
- `DELETE /v1/session` — `Station-Session` header; clean shutdown.
  Idempotent, matching §3.4's close semantics.
- `POST /v1/events` — NDJSON batch of StationEvents (§6) into the
  bounded ring; carries session liveness (§3.4 — no separate
  heartbeat). Lenient by design (events never fail an operation):
  malformed lines are counted and skipped; an over-limit batch gets a
  structured `station_body_limit` and keeps what was already scanned.
- `GET /v1/tap[?plugin=ref]` — live NDJSON stream of events as they
  arrive; chunked, quiet when idle, no backlog replay. A slow tap
  consumer drops (counted in status), never stalls ingest.
- `GET /v1/status` — sessions and plugins with state and self-reported
  process identity, ring fill and drop counters, tap subscribers,
  configured bounds, uptime. Expired sessions are purged before
  reporting — truthful liveness, no ghosts (§3.4).

## Error shape and codes

Every error is the one structured shape:

```json
{ "error": { "code": "station_protocol", "message": "..." } }
```

Codes follow §14's house grammar. Where the shared catalog
(`station/typescript/src/error.ts`, pinned by the `errors` corpus
section) covers the condition, the catalog string is used —
`station_protocol` for version rejection, `station_body_limit` for
over-limit bodies. Five daemon-boundary conditions the catalog does not
(yet) cover use grammar-conformant transport codes, proposed as catalog
additions: `station_token_allow` (bearer token missing/wrong),
`station_origin_allow` (Host/Origin rejected), `station_no_session`
(unknown or expired session — re-register), `station_register_invalid`
(malformed register body), `station_no_route` (unknown path/method).
None of these surfaces as a library `err.code`: per §14, auth and proof
failures degrade exactly like proxy absence.

## Develop

```
make build   # go.work against the sibling sekreto checkout, then build
make test    # go test -count=1 ./...
make vet     # go vet ./...
make clean
```

The generated `go.work` points at the sibling `voxgig/sekreto` checkout
(set `SEKRETO_HOME` if it is somewhere unusual) even though nothing
imports it yet — so the R2 phase's `require` is a one-line change.
Standard library only, deliberately: the proxy holds secrets when R2
lands, so it is the hardening focus and keeps a minimal dependency
surface (§15).
