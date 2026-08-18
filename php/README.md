# voxgig/station - PHP

PHP port of the canonical TypeScript implementation
(`typescript/src/`). Solo mode only in v1 (the proxy is a deferred
amplifier - design station.md 2.2, tier table): no wire client.

```php
require_once 'station/php/src/Station.php';   // or composer: voxgig/station

use Voxgig\Station\Station;

$station = Station::open();                          // profile/env all defaulted
$pad = $station->connect(TaskpadSDK::class, ['base' => $base]);

$result = $pad->Todo()->list();
$station->tap(fn($ev) => print(json_encode($ev) . "\n"));
```

Inverted binding (design station.md 3.1) works on the constructor the
SDK already generates:

```php
$pad = new TaskpadSDK($station->options(['base' => $base]));
```

## Dependencies

[voxgig/sekreto](https://github.com/voxgig/sekreto)'s PHP port is the
one dependency (design station.md 5): station names a secret, sekreto
resolves it. sekreto/php ships as `require_once and nothing else` (no
composer package yet), so `src/Sekreto.php` locates it - an
already-loaded `Voxgig\Sekreto\Sekreto` class wins, then
`SEKRETO_HOME`, then the usual sibling-checkout locations. No other
dependency, no third-party code.

## Layout

| File | Contents |
|---|---|
| `src/Station.php` | the core: ambient instance, registry, transport middleware, binding forms |
| `src/Adapter.php` | `feature_binding` (the ONE binding path), the carried adapter, the wrap marker |
| `src/Descriptor.php` | descriptor normalizer + canonical serializer, envtoken/secretname rules |
| `src/Secrets.php` | the secret broker over sekreto: placeholder, miss-vs-error, exact-value scrub |
| `src/Profile.php` | station.json lookup, profile selection + wholesale-providers resolution |
| `src/Events.php` | bounded ring buffer + tap |
| `src/Error.php` | the station.md 14 error-code catalog |

## Test

```sh
make test          # conformance corpus (spec/station.json via voxgig/omni) + unit tests,
                   # then the live quickstart against a generated PHP SDK (skips without one)
php test/run.php secretname   # one corpus/unit group
```

The conformance suite finds the sibling `voxgig/omni` checkout via
`OMNI_HOME` (same convention as sekreto/php). The quickstart suite runs
against a generated taskpad PHP SDK (`STATION_TEST_SDKS`, default
`/home/user/voxgig-sdk`) and the taskpad test server
(`test/api/taskpad/server.js`), and skips rather than fails when either
is absent.

## Notes

- PHP (NTS) is single-threaded per request, so the library carries no
  locks; the observable contract (serialized taps, bounded buffers -
  design station.md 10.2) is unchanged.
- PHP arrays are value types: an empty map and an empty list are the
  same value, so `canonical_serialize` emits `[]` where another port
  would emit `{}` for an empty map that arrived as a PHP array (the
  omni php port documents the same variance); a deliberate `(object)[]`
  map keeps `{}`. Value semantics also make copy-on-inject (design
  station.md 5.3) hold by construction - the middleware still swaps
  only its own copy.
- Process-per-request runtimes run solo by default (design station.md
  3.4); the attached-mode rejoin handshake arrives with the proxy.
