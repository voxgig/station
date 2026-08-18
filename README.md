# station

`voxgig/station` — one control surface for outbound integrations.

Station sits between an application and all of its generated
[sdkgen](https://github.com/voxgig/sdkgen) SDKs. Each SDK registers with
a local station as a plugin, making station the single place where
outbound integrations are configured, credentialed, observed, policed,
and debugged — for the developer and for an AI agent working on or
through the application.

Secrets are brokered through
[voxgig/sekreto](https://github.com/voxgig/sekreto); application code
names a secret, never a value.

## Status

Design plus a working TypeScript spike of the solo-mode library core.
The proxy (D2) is deliberately deferred; everything here runs
in-process.

- [`docs/design/station.md`](./docs/design/station.md) — the full design:
  the plugin contract, the descriptor, secret placement, observability
  and debugging, the MCP agent surface, the wire protocol and companion
  proxy, the sdkgen integration, and delivery phasing.
- [`typescript/`](./typescript/) — the canonical library port (spike):
  `Station.open`/`connect`/`adopt`, the descriptor normalizer and
  canonical serializer, profile resolution over `station.json`, the
  sekreto-backed secret broker with placeholder injection at the
  transport seam, the event ring and `tap`, and the solo half of the
  hosts policy. Integration suites run against real sdkgen-generated
  SDKs (solardemo plus the two test APIs below).
- [`spec/`](./spec/README.md) — the omni conformance corpus (the
  pure-contract sections; the SDK-machinery sections live in the
  integration suites for now).
- [`test/api/`](./test/api/) — synthetic test APIs (OpenAPI spec +
  dependency-free server each): `taskpad`, a plain CRUD API with a raw
  apiKey scheme, and `gnarly-pets`, a deliberately awkward one — Bearer
  auth, error envelopes that echo the presented credential, a redirect
  to an off-policy host, fat `Set-Cookie` headers, pagination.

Run the spike: `make test` (needs sibling `sekreto` and `omni`
checkouts; the integration suites also need generated SDKs, see
`typescript/test/*.test.ts`, and skip cleanly without them).
