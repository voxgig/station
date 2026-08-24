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

Design plus solo-mode library ports across the sdkgen target set, and
the `@voxgig/sdkgen-station` feature package that turns generated SDKs
into station plugins. The proxy (D2) is deliberately deferred;
everything here runs in-process.

| port | dir | secrets | validated here | declarative config |
|---|---|---|---|---|
| TypeScript (canonical) | `typescript/` | sekreto | full suite + live e2e | full declarative front door |
| JavaScript | `javascript/` | sekreto-js | full suite + live e2e | sdk grammar (front door pending) |
| Go | `go/` | sekreto go | unit + conform suites | sdk grammar (front door pending) |
| Python | `python/` | sekreto py | unit + conform suites | sdk grammar (front door pending) |
| Ruby | `ruby/` | sekreto rb | full suite + live e2e | sdk grammar (front door pending) |
| PHP | `php/` | sekreto php | full suite + live e2e (locally; not in CI) | sdk grammar (front door pending) |
| Perl | `perl/` | sekreto perl (vendored into SDKs) | full suite + live e2e | sdk grammar (front door pending) |
| Java | `java/` | sekreto java | unit + conform suites | sdk grammar (front door pending) |
| Kotlin | (rides the java library, JVM interop) | — | generation-validated | rides java |
| C# | `csharp/` | sekreto csharp | written; no local .NET toolchain | pre-rename `plugin` grammar |
| Swift | `swift/` | env-only | written; no local toolchain | pre-rename `plugin` grammar |
| Dart | `dart/` | env-only | written; no local toolchain | pre-rename `plugin` grammar |
| Elixir | `elixir/` | env-only | written; no local toolchain | pre-rename `plugin` grammar |
| Lua | `lua/` | env-only (vendored into SDKs) | suite run under a JS Lua VM | pre-rename `plugin` grammar |
| Rust | `rust/` | sekreto rust | unit + conform suites | sdk grammar (front door pending) |
| C (tier C) | `c/` | env-only (vendored) | unit + conform suites | sdk grammar (front door pending) |
| C++ (tier C) | `cpp/` | env-only (vendored) | unit + conform suites | sdk grammar (front door pending) |

The declarative-config column is the status the design's §12 promises
this table: the TypeScript port carries the full front door
(`station.sdk()`/`create()`/`check()`, struct-validated config,
feature management); the other CI ports speak the `sdk`/`api` instance
grammar with the front door pending; the five toolchain-gated ports
are still on the pre-rename `plugin` grammar (see `spec/README.md`).

Deferred per the design's §9.1/§17: scala, clojure, haskell, ocaml,
zig, lean adapters (monolithic feature modules or static reference
points), and everything proxy-side.

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
