# station - Swift

Swift port of the canonical TypeScript implementation
([`../typescript`](../typescript)) of the station library core - solo
mode ([design](../docs/design/station.md) D1): plugin registry,
profiles, the env-only secret broker, the descriptor normalizer +
canonical serializer, the event ring/tap, and the transport middleware
decisions the generated station feature delegates to.

```sh
make test         # links vendor/omni to the sibling voxgig/omni checkout, then `swift test`
make build-clean  # removes the link and builds the LIBRARY alone - the proof
                  # that nothing shipped names omni (register 4.13)
```

## Use

Swift is an inverted-binding target (design 3.1): the app constructs the
SDK through its existing generated constructor and hands it
station-built options. The generated adapter ships a `stationOptions()`
sugar that builds the SDK's own options-map form:

```swift
import VoxgigStation

let st = try Station.open()                    // profile/env all defaulted
let sdk = TaskpadSDK(stationOptions(st))       // was: TaskpadSDK(opts-with-apikey)

_ = st.tap { ev in print(ev) }                 // live events
```

Map-form activation (`feature: [station: [active: true]]` in the SDK
options) binds to the ambient instance instead; only `Station.open()`
creates it (binding is never implicit, design 3.1).

## Secrets are env-only, and this port says so

There is **no Swift sekreto port** (design 2.2), so solo-mode secrets
come from exactly one store: the process environment, read under the
envtoken name (`voxgig_solardemo.apikey` -> `VOXGIG_SOLARDEMO_APIKEY` -
the env var the generated SDK's README already documents). A profile
chain naming any other provider kind is refused with
`station_secret_error` rather than silently skipped (a fall-through
would quietly reach for a weaker store, design 5.2), and the
construction warning event names the unavailable kinds. Vault access for
Swift apps is attached mode with `resolve: proxy` - the proxy's Go
sekreto runs the chain (design 2.2); the permanent fix is a sekreto
Swift port, contributed to sekreto (design 18).

## Layout

| File | Contents |
|---|---|
| `Sources/VoxgigStation/Station.swift` | ambient instance, options(), featureBinding, registry, status/close |
| `Sources/VoxgigStation/Binding.swift` | per-plugin hook bridge + transport middleware decisions |
| `Sources/VoxgigStation/Descriptor.swift` | descriptor v1 normalizer, envToken, canonical serializer |
| `Sources/VoxgigStation/Profile.swift` | station.json lookup, the design-3.3 api/sdk instance merge (wholesale providers replacement) |
| `Sources/VoxgigStation/Secrets.swift` | env-only broker: placeholder, hoist, miss-vs-error, floor-less scrub |
| `Sources/VoxgigStation/Events.swift` | bounded ring + serialized tap |
| `Sources/VoxgigStation/Error.swift` | the design-14 error-code catalog |
| `Sources/VoxgigStation/Json.swift` | in-tree JSON value model + parser (no NSNumber bool/number conflation) |
| `Tests/VoxgigStationTests/ConformTest.swift` | the shared `spec/station.json` corpus, via voxgig/omni |
| `Tests/VoxgigStationTests/StationTest.swift` | unit cases the corpus cannot reach without an SDK |

## Notes

- The generated Swift SDKs vendor their own `Value` type, so the
  physical fetcher wrap and the copy-on-inject deep clone live in the
  generated `StationFeature.swift` adapter; every *decision* (wrap
  position, hosts policy, injection, event shapes) lives here - the rust
  port's arrangement, for the same reason.
- The library carries its own `Json` enum and parser (as the omni Swift
  port does) because Foundation's NSNumber bridge does not keep booleans
  and numbers distinct on every platform.
- `vendor/omni` is a committed relative symlink to `../../../omni/swift`
  (the standard sibling-checkout layout); `make vendor` re-links it when
  the checkout sits elsewhere (`OMNI_HOME`).
