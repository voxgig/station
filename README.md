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

The solo-mode library is written in sixteen languages and is green in
CI in all of them, beside the `@voxgig/sdkgen-station` feature package
that turns generated SDKs into station plugins. Three ports have a
release route: `@voxgig/station` and `@voxgig/station-js` on npm, and
the Go module by tag. The others are consumed from this repository.

The proxy (D2) is written, in [`proxy/`](./proxy/), and is not usable
yet: no library port attaches to it, and CI does not build it.
Everything a library does today runs in-process.

**The plan, the per-item register and the current status are in
[`docs/plan/`](./docs/plan/README.md).** The table below is for
orientation; that directory is the authority.

| port | dir | secrets | tested in CI | declarative config |
|---|---|---|---|---|
| TypeScript (canonical) | `typescript/` | sekreto | unit, corpus (11 sections), plugin conformance | full declarative front door |
| JavaScript | `javascript/` | sekreto-js | unit, corpus (11) | full declarative front door |
| Go | `go/` | sekreto go | unit, corpus (11) | full declarative front door |
| Python | `python/` | sekreto py | unit, corpus (11) | full declarative front door |
| Ruby | `ruby/` | sekreto rb | unit, corpus (11) | full declarative front door |
| PHP | `php/` | sekreto php | unit, corpus (11) | full declarative front door |
| Perl | `perl/` | sekreto perl (vendored into SDKs) | unit, corpus (11) | full declarative front door |
| Java | `java/` | sekreto java | unit, corpus (11) | full declarative front door |
| Kotlin | (rides the java library, JVM interop) | — | generation-validated | rides java |
| C# | `csharp/` | sekreto csharp | unit, corpus (8) | `sdk` grammar; front door pending |
| Swift | `swift/` | env-only | unit, corpus (8) | `sdk` grammar; front door pending |
| Dart | `dart/` | env-only | unit, corpus (8) | `sdk` grammar; front door pending |
| Elixir | `elixir/` | env-only | unit, corpus (8) | `sdk` grammar; front door pending |
| Lua | `lua/` | env-only (vendored into SDKs) | unit, corpus (8) | `sdk` grammar; front door pending |
| Rust | `rust/` | sekreto rust | unit, corpus (11) | full declarative front door |
| C (tier C) | `c/` | sekreto c, vendored (the SDK payload is built env-only) | unit, corpus (11), secret store | full declarative front door; config arrives in code (`vxstn_open` takes the JSON), so a consumer that reads `station.json` itself is fine |
| C++ (tier C) | `cpp/` | env-only (vendored) | unit, corpus (11) | full declarative front door |

The declarative-config column is the status the design's §12 promises
this table. Eleven ports carry the full front door
(`station.sdk()`/`create()`/`check()`, struct-validated config,
feature management) and run all eleven sections of the conformance
corpus. C#, Swift, Dart, Elixir and Lua read the `sdk`/`api` instance
grammar and run eight sections; the front door is their remaining
tranche (see `spec/README.md`).

CI runs every port's unit and corpus suites. The end-to-end suites run
against real generated SDKs and skip in CI, which generates none.

Deferred per the design's §9.1/§17: scala, clojure, haskell, ocaml,
zig, lean adapters (monolithic feature modules or static reference
points). Not built yet: attaching a library to the proxy, and the
proxy features `proxy/README.md` lists as deferred.

- [`docs/plan/`](./docs/plan/README.md) — the plan and its registers:
  the workstreams in order, one row per item with its evidence, what
  each dependency owes, and the current status of every port.
- [`docs/design/station.md`](./docs/design/station.md) — the full design:
  the plugin contract, the descriptor, secret placement, observability
  and debugging, the MCP agent surface, the wire protocol and companion
  proxy, the sdkgen integration, and delivery phasing.
- [`docs/design/station-declarative-config.md`](./docs/design/station-declarative-config.md)
  — declarative config and dynamic SDK instances: `station.json`
  declares named SDK instances, `station.sdk(name)` returns one, the
  registry is keyed by instance rather than by API, and the config is
  validated with [voxgig/struct](https://github.com/voxgig/struct) so
  that the grammar cannot express a credential, plus universal
  management of SDK features. Implemented in the TypeScript port
  (Stages 1–3b of its §12), no longer a pure proposal; its §16
  amendments are folded into the full design.
- [`docs/design/station-and-plugin.md`](./docs/design/station-and-plugin.md)
  — the settled agreement with
  [voxgig/plugin](https://github.com/voxgig/plugin), which names
  station as its first host: what the two designs share, where they
  disagreed, and which side moved. The core of it: adopt the model
  now (`name$tag` refs, the precedence ladder, constraint-and-band
  ordering), take the library as a dependency only when it has ports.
  Pinned to a specific plugin revision and re-pinned as its design
  advances.
- [`docs/design/station-and-plugin-plan.md`](./docs/design/station-and-plugin-plan.md)
  — the cross-repo sequencing that neither per-repo plan can state
  from inside its own repo: the two tracks, the four meeting points,
  and the four obligations (C1–C4) the build-natively decision hangs
  on, with their current state.
- [`sdkgen-station/`](./sdkgen-station/) — the sdkgen feature package
  (design §9 item 5): the feature model, per-target adapter overlays,
  and the deps that flow each target's station library into generated
  manifests. `voxgig-sdkgen package add @voxgig/sdkgen-station`.
- [`typescript/`](./typescript/) — the canonical library port:
  `Station.open`/`connect`/`adopt`, the descriptor normalizer and
  canonical serializer, profile resolution over `station.json`, the
  sekreto-backed secret broker with placeholder injection at the
  transport seam, the event ring and `tap`, and the solo half of the
  hosts policy. Integration suites run against real sdkgen-generated
  SDKs (solardemo plus the two test APIs below).
- [`proxy/`](./proxy/) — the companion proxy daemon, `voxgig-station`
  (design D2, §8): the wire surface, proxy-side policy, capture, tap
  and the MCP tools. No library attaches to it yet and CI does not
  build it; [`docs/plan/status.md`](./docs/plan/status.md) has its
  state.
- [`spec/`](./spec/README.md) — the omni conformance corpus (the
  pure-contract sections; the SDK-machinery sections live in the
  integration suites for now).
- [`test/api/`](./test/api/) — synthetic test APIs (OpenAPI spec +
  dependency-free server each): `taskpad`, a plain CRUD API with a raw
  apiKey scheme, and `gnarly-pets`, a deliberately awkward one — Bearer
  auth, error envelopes that echo the presented credential, a redirect
  to an off-policy host, fat `Set-Cookie` headers, pagination.

Run the spike: `make test` (needs sibling `sekreto`, `struct`, `plugin`
and `omni` checkouts; the integration suites also need generated SDKs, see
`typescript/test/*.test.ts`, and skip cleanly without them).
