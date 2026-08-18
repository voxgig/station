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

| port | dir | secrets | validated here |
|---|---|---|---|
| TypeScript (canonical) | `typescript/` | sekreto | full suite + live e2e |
| JavaScript | `javascript/` | sekreto-js | full suite + live e2e |
| Go | `go/` | sekreto go | full suite + live e2e |
| Python | `python/` | sekreto py | full suite + live e2e |
| Ruby | `ruby/` | sekreto rb | full suite + live e2e |
| PHP | `php/` | sekreto php | full suite + live e2e |
| Perl | `perl/` | sekreto perl (vendored into SDKs) | full suite + live e2e |
| Java | `java/` | sekreto java | full suite + live e2e |
| Kotlin | (rides the java library, JVM interop) | — | generation-validated |
| C# | `csharp/` | sekreto csharp | written; no local .NET toolchain |
| Swift | `swift/` | env-only | written; no local toolchain |
| Dart | `dart/` | env-only | written; no local toolchain |
| Elixir | `elixir/` | env-only | written; no local toolchain |
| Lua | `lua/` | env-only (vendored into SDKs) | suite run under a JS Lua VM |
| Rust | `rust/` | sekreto rust | full suite |
| C (tier C) | `c/` | env-only (vendored) | full suite + live e2e |
| C++ (tier C) | `cpp/` | env-only (vendored) | full suite + live e2e |

Deferred per the design's §9.1/§17: scala, clojure, haskell, ocaml,
zig, lean adapters (monolithic feature modules or static reference
points), and everything proxy-side.

- [`docs/design/station.md`](./docs/design/station.md) — the full design:
  the plugin contract, the descriptor, secret placement, observability
  and debugging, the MCP agent surface, the wire protocol and companion
  proxy, the sdkgen integration, and delivery phasing.
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
