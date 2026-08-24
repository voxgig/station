# voxgig-station — the station companion proxy

The optional companion daemon of [voxgig/station](../README.md) (design
D2): the consolidated control surface for every attached station
library, and — as of the data-plane phase — the credential-injecting,
policy-enforcing, capturing forward hop for their traffic. The
authoritative design is
[`docs/design/station.md`](../docs/design/station.md) — principally §8
(wire protocol and proxy), §5.3 (isolation rungs / R2), §6 (events),
§14 (failure modes and error codes), §15 (security posture), §16
(policy) — plus [`docs/design/decisions.md`](../docs/design/decisions.md)
(per-instance grants; single-team v1).

## Scope: v1 core

- **Single-team, fully mutually trusting** (§8.4, D-2026-08-24-2): the
  proof-of-token gate is the entire authn story; no per-principal state
  anywhere. A shared cross-team deployment is unsupported until the v2
  authorization design exists.
- **In-memory stores**: sessions, the event ring, grants, and the
  capture store live in process memory. The only thing persisted is the
  approval state file (blessed base/hosts/name triples — never secret
  values), beside the token file. Secret values live in memory only
  (§8.5): sekreto providers are readers, and the proxy writes no copy
  of a credential anywhere on disk.
- **Local loopback TCP only**: default `127.0.0.1:8299`; unix socket
  and remote (TLS) modes are later phases.

Still to come (seams left): replay/mock/record over the capture store,
the traffic query endpoint, OTLP export, and the MCP surface (§7).

## Run

```
make build          # builds ./voxgig-station
./voxgig-station run
```

Flags for `run`:

| flag | default | design |
|---|---|---|
| `--listen` | `127.0.0.1:8299`, or `VOXGIG_STATION_URL` (the flag wins) | §8.1 |
| `--token-file` | `~/.voxgig/station/token` | §8.1 |
| `--config` | cwd-up lookup to the repo root, then `~/.voxgig/station.json` | §8.3, §3.5 |
| `--profile` | `VOXGIG_STATION_PROFILE`, else `default` | §3.5 |
| `--state-file` | `approvals.json` beside the token file | §8.3 |
| `--session-ttl` | `5m` (unpinned by the design; liveness rides `/v1/events`) | §3.4 |
| `--grant-ttl` | `15m` | §5.3 |
| `--ring` | `10000` entries | §8.5 |
| `--capture-entries` / `--capture-bytes` | `10000` / `256MB` | §8.5 |

On first run the daemon creates the token file (0600, inside a 0700
directory). Every request except `GET /v1/health` requires it as a
bearer token, compared in constant time. It is never logged.

## The policy authority (§8.3)

Everything a client registers is **untrusted input**. The proxy loads
its *own* `station.json` (same lookup and §3.5 profile merge as the
libraries), and from it derives, per instance ref: the hosts egress
allowlist, the instance→secret-name mapping (explicit `secret`, else
the §5.1 `envtoken` derivation), `resolve: library|proxy`, and
`capture: meta|headers|full`. The profile's `secrets.providers` chain
is handed to the proxy's own sekreto verbatim.

There is no first-seen shortcut. A registered instance parks in
**`pending`** — visible in status, capture and library-resolved traffic
working — until `POST /v1/approve/{ref}` blesses its base/hosts/name
triple. The blessed triple persists in the state file; any later change
to it re-enters pending. A registered descriptor can only **narrow**
approved policy (a base host inside the allowlist narrows the session
to it), never widen it, and never selects which secret is resolved.
Egress to a host off the effective allowlist is `station_host_allow`.

Approved instances with `resolve: proxy` get an **R2 grant** at
registration (`{grant, grantTtlSeconds}` in the binding): per-instance
(D-2026-08-24-1), session-bound, 15m TTL, renewed by re-registration,
revoked by `DELETE /v1/grants/{ref}`. An expired, revoked, or
cross-instance grant is `station_grant_expired` — re-register.

## Wire surface (protocol 1)

All endpoints except `/v1/health` require `Station-Protocol: 1` and
`Authorization: Bearer <token>` (§8.6 N/N−1 acceptance: v1's accepted
set is `{1}`). `Host` and `Origin` are validated on every request —
§8.1's DNS-rebinding hardening.

- `GET /v1/health[?nonce=N]` — the single unauthenticated endpoint;
  with a nonce, `Station-Proof: hex(HMAC-SHA256(token, nonce))` lets a
  client verify the daemon before sending anything sensitive (§8.1).
- `POST /v1/register` — `{descriptor, process, instance?, identity?}`
  → `{session, binding}`. The binding reports the proxy-side effective
  policy: `{state, capture, resolve, protocol, ttlSeconds}` plus, when
  approved, `hosts` (narrowed), `secret` (the *name*), and for
  `resolve: proxy` the `grant`.
- `DELETE /v1/session` — clean shutdown; idempotent (§3.4).
- `POST /v1/events` — NDJSON batch into the bounded ring; carries
  session liveness. Lenient: events never fail an operation (§6).
- `GET /v1/tap[?plugin=ref]` — live NDJSON stream; quiet when idle.
- `POST /v1/forward` — the §8.2 data plane. Request: a JSON envelope
  `{url, method, headers, body}` (buffered, 32MB limit →
  `station_body_limit`) plus `Station-Session` / `Station-Plugin` /
  `Station-Corr` / `Station-Grant` / `Station-Redact` headers.
  Response: the **raw upstream body** as the response body (chunked,
  binary-safe), `Station-Status` carrying the upstream status, and
  every upstream header as `Station-Up-<name>`, repeats preserved.
  The upstream client **never follows redirects** — a 3xx rides back
  like any response, so a `Location` off the allowlist cannot pull an
  automatic credentialed follow-up. `Station-Redact`-named envelope
  header values are held transiently for the one exchange, scrubbed
  from its capture, then discarded unwritten (§15).
- `POST /v1/approve/{ref}` — bless the triple (the HTTP surface under
  the `voxgig-station approve` CLI verb).
- `DELETE /v1/grants/{ref}` — revoke one instance's grants.
- `GET /v1/policy/{ref}[?version=N]` — the effective policy view;
  with `version`, a long-poll held until the version changes or 25s.
- `GET /v1/status` — sessions/plugins with live state, ring fill,
  capture store fill (entries/bytes/evicted/degraded), active grants,
  policy coverage and approvals, every bound, uptime.

## Capture (§8.5, §15)

An in-memory store bounded to 10k entries / 256MB (oldest evicted
first), per-instance depth `meta | headers | full` from proxy config
(default `meta`). Redaction happens **at capture time, never
retroactively**: the seeded header redact-list, the exchange's
`Station-Redact` values (both `Bearer x` and bare forms), and every
value the proxy's broker ever resolved are scrubbed — exact match, no
length floor — before an entry is stored, so secret bytes never enter
the store. `full` bodies truncate at 64KB with a `truncated` marker.
Each entry records `replayable`: false when the request body was
truncated or body redaction replaced bytes the request needs —
redacted *auth headers* are the exception, since replay restores them
through the credential path. A `full`-depth exchange carrying a real
credential in a redact-list header that `Station-Redact` does not name
degrades to `headers` (counted in status) rather than storing a body
the proxy cannot scrub.

## Error shape and codes

Every error is `{"error":{"code","message"}}`. Catalog codes
(`station/typescript/src/error.ts`) are used wherever the catalog
covers the condition: `station_protocol`, `station_body_limit`,
`station_host_allow`, `station_grant_expired`,
`station_secret_no_value`, `station_secret_error`,
`station_config_invalid`. Seven daemon-boundary conditions use
grammar-conformant transport codes proposed as catalog additions:
`station_token_allow`, `station_origin_allow`, `station_no_session`,
`station_register_invalid`, `station_forward_invalid`,
`station_upstream`, `station_no_route`. Per §14, auth and proof
failures read as proxy absence to libraries.

## Develop

```
make build   # go.work against the sibling sekreto checkout, then build
make test    # go test -count=1 ./...
make vet
make clean
```

The generated `go.work` points at the sibling `voxgig/sekreto`
checkout (set `SEKRETO_HOME` if it is somewhere unusual); the module
requires `github.com/voxgig/sekreto/go` — the proxy's only dependency,
per §10's discipline: the proxy holds secrets, so it is the hardening
focus and keeps a minimal dependency surface (§15).
