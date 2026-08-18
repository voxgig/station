# station - Elixir

Elixir port of the canonical TypeScript implementation
(`typescript/src/`). Solo mode only in v1 (the proxy is a deferred
amplifier): plugin registry, profiles, env-only secret broker with
placeholder injection, bounded event ring + tap, descriptor normalizer
and canonical serializer.

```sh
make test        # mix test: unit suites + the spec/station.json corpus
                 # through the sibling voxgig/omni checkout (OMNI_HOME)
```

## Use (inside a generated Elixir SDK)

Inverted binding is the primary form for Elixir's functional SDKs
(design station.md 3.1):

```elixir
st = Voxgig.Station.open()
solar = Solardemo.new(Voxgig.Station.options(st))
```

`connect/3` and `adopt/3` are the same construction as sugar, and carry
the library's adapter on `options.extend` for SDKs generated without the
station feature:

```elixir
solar = Voxgig.Station.connect(st, Solardemo)
```

## Layout

| File | Contents |
|---|---|
| `lib/voxgig/station.ex` | the core: ambient instance, registry, broker + policy decisions, events |
| `lib/voxgig/station/adapter.ex` | the struct-facing half: feature binding, wrap-position guard, transport middleware, hook bridge, carried adapter |
| `lib/voxgig/station/descriptor.ex` | envtoken/secretname grammar, descriptor normalizer, canonical serializer |
| `lib/voxgig/station/profile.ex` | station.json lookup + profile resolution |
| `lib/voxgig/station/secrets.ex` | the env-only broker (no Elixir sekreto port - it says so) |
| `lib/voxgig/station/events.ex` | bounded ring + taps |
| `lib/voxgig/station/error.ex` | the station.md 14 error catalog |
| `lib/voxgig/station/json.ex` | dependency-free JSON parser for station.json |

## Notes

- **Secrets are env-only, and the library says so** (design station.md
  2.2): no Elixir sekreto port exists, so the broker reads the process
  environment directly under the sekreto env key of the secret name
  (`voxgig_solardemo.apikey` -> `VOXGIG_SOLARDEMO_APIKEY`). A chain
  naming any other store warns at construction and errors (never falls
  through) when resolution reaches it.
- A station instance is a tagged reference whose state lives in a public
  named ETS table - deliberately the generated SDKs' vendored
  `Voxgig.Struct` heap arrangement, hazards included (the table dies
  with the first process that touched the module; a dead ambient handle
  reads as "no station open").
- `Voxgig.Struct` ships inside each generated SDK, not on hex, so only
  `Voxgig.Station.Adapter` references it (resolved at runtime); the core
  and the pure modules compile and test with no SDK present.
- Zero dependencies; the JSON parser is the omni port's, with integers.
