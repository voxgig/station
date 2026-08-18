# station - Dart

Dart port of the canonical TypeScript implementation
(`typescript/src/`). Solo mode only in v1 (the proxy is a deferred
amplifier): plugin registry, profiles, env-only secret broker with
placeholder injection, bounded event ring + tap, descriptor normalizer
and canonical serializer.

```sh
make test        # dart run test/run.dart: unit suites + the
                 # spec/station.json corpus through the sibling
                 # voxgig/omni checkout (../../omni - Dart imports are
                 # static, so the sibling layout is assumed)
make build       # dart analyze
```

## Use (inside a generated Dart SDK)

The two-line quickstart (design station.md 11) - pass the generated
constructor as a tear-off:

```dart
import 'package:voxgig_station/voxgig_station.dart';

final station = Station.open();
final pad = station.connect(TaskpadSDK.new);

final todos = await pad.Todo().list();
```

Inverted binding works on the constructor the SDK already generates:

```dart
final st = Station.open();
final pad = TaskpadSDK(st.options());
```

`adopt()` is the retrofit path for SDKs generated without the station
feature - the library's carried adapter rides `options.extend` and the
generated constructor's featureorder tolerance (sdkgen station.md 9.3):

```dart
final pad = station.adopt(TaskpadSDK.new, {'apikey': resident});
```

## Layout

| File | Contents |
|---|---|
| `lib/src/station.dart` | the core: ambient instance, registry, transport middleware + policy, events surface |
| `lib/src/adapter.dart` | featureBinding, wrap-position guard, the callable-class transport wrap, hook bridge, carried adapter |
| `lib/src/descriptor.dart` | envtoken/secretname grammar, descriptor normalizer, canonical serializer |
| `lib/src/profile.dart` | station.json lookup + profile resolution |
| `lib/src/secrets.dart` | the env-only broker (no Dart sekreto port - it says so) |
| `lib/src/events.dart` | bounded ring + taps |
| `lib/src/error.dart` | the station.md 14 error catalog |

## Notes

- **Secrets are env-only, and the library says so** (design station.md
  2.2): no Dart sekreto port exists, so the broker reads
  `Platform.environment` directly under the sekreto env key of the
  secret name (`gnarly_pets.apikey` -> `GNARLY_PETS_APIKEY`). A chain
  naming any other store warns at construction and errors (never falls
  through) when resolution reaches it.
- **The transport wrap is a callable class** (`StationTransport`), not a
  closure: Dart closures cannot carry the ts port's `__station__` marker
  property, so the wrap's concrete type IS the double-wrap/position
  marker, checked with `is`.
- **Errors travel as values.** The transport middleware returns
  `StationError` (an `Exception` carrying `code`/`message`) instead of
  throwing, matching the generated dart pipeline's `iserr` convention;
  only construction-time misuse (open conflict, wrap order, double
  bind) throws.
- The hook bridge keeps its per-operation correlation state in
  `ctx.out['station$']` - the per-op scratch map every generated
  Context carries (the same slot the java/csharp ports use).
- Zero dependencies: `dart:io` + `dart:convert` only. The committed
  `.dart_tool/package_config.json` makes `dart run` work offline with
  no pub resolution.
