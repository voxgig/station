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

## The declarative front door (design station.md 6)

`station.json` declares the instances; the application asks for one by
name and gets a constructed, bound, credentialled client.

```php
Station::provide('taskpad', [
    'construct' => fn(array $options) => new TaskpadSDK($options),
    'config' => TASKPAD_CONFIG,       // the SDK's own static config
]);

$station = Station::open();
$pad = $station->sdk('taskpad');          // constructed once, then cached
$scoped = $station->create('taskpad');    // uncached, auto-tagged `taskpad$1`

$station->instances();   // every DECLARED instance, sorted
$station->features();    // instance x feature, with per-value provenance
$station->check();       // construct every active instance - for CI
$station->warm();        // batch-resolve the fleet's secrets
```

An instance ref is `<api>` or `<api>$<tag>` (design 6.1). `as` is a
TAG, never a free name: `connect(SDK, ['as' => 'test'])` on api
`stripe` is the instance `stripe$test`.

## Dependencies

Two, and no third-party code beyond them.

[voxgig/sekreto](https://github.com/voxgig/sekreto)'s PHP port (design
station.md 5): station names a secret, sekreto resolves it.
[voxgig/struct](https://github.com/voxgig/struct)'s PHP port backs
`validate_config` (design 4) - a RUNTIME dependency, since validation
runs at `open()` and not only under test.

Neither ships as a composer package yet, so this port locates them the
same way: an already-loaded class wins, then `SEKRETO_HOME` /
`STRUCT_HOME`, then the usual sibling-checkout locations
(`src/Sekreto.php`, `src/Structhome.php`). `spec/config-shape.json` is
read from the repo at runtime - this port runs from `src/` like the
javascript one, so it reads the artifact every port reads rather than
shipping a mirror.

## Layout

| File | Contents |
|---|---|
| `src/Station.php` | the core: ambient instance, instance-keyed registry, transport middleware, binding forms, the declarative front door |
| `src/Adapter.php` | `feature_binding` (the ONE binding path), the carried adapter, the wrap marker, the policy allowlist |
| `src/Descriptor.php` | descriptor normalizer + canonical serializer, envtoken/secretname rules |
| `src/Secrets.php` | the secret broker over sekreto: placeholder, miss-vs-error, exact-value scrub |
| `src/Profile.php` | station.json lookup, config scope, profile selection + wholesale-providers resolution |
| `src/Shape.php` | `normalize_config` / `validate_config`: the defaults tables, the struct run, the 4.4 and 5.2 scans |
| `src/Feature.php` | the 8.3 merge, the 8.4 constraint-and-band order + station pin, the 8.5 descriptor-derived checker |
| `src/Factory.php` | the process-global factory table: `provide`, `factory_for`, `provided` |
| `src/Loader.php` | `check_package`, `factory_from_module`, `load_sync` - the 6.3 loader |
| `src/Kind.php` | the one place php's map/list ambiguity is decided |
| `src/Structhome.php` | locate the sibling voxgig/struct checkout |
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

**Section completeness is a test, not a habit.** `test/run.php`
declares two named tables - `$DRIVERS`, one subject per corpus section
this port runs, and `$PENDING`, sections deliberately not run with the
reason written down. The per-section tests are registered by iterating
`$DRIVERS`, so a listed section cannot silently fail to run, and the
`sections-covered` test reads `spec/station.json` directly and asserts
that the two tables' keys exactly cover the corpus's own. A section
added upstream and not picked up here fails loudly; so does a stale
driver or a stale pin. All ten corpus sections run; `$PENDING` is
empty.

## Notes

- PHP (NTS) is single-threaded per request, so the library carries no
  locks; the observable contract (serialized taps, bounded buffers -
  design station.md 10.2) is unchanged. The factory table is
  process-global by design and is a static property, with
  `reset_factories()` as the test seam.
- **PHP arrays are value types, and an empty array is at once `{}` and
  `[]`.** That is this port's one representational gap (the omni and
  struct php ports document the same one), and `src/Kind.php` is the
  only place it is decided. Normalization reads `{}` as a map, so
  `sdk: {"solar": {}}` still gains its block defaults; validation reads
  `[]` as a list, so the shape still rejects a list where a map belongs.
  The two collide only on a container the normalizer SYNTHESIZES, so
  `normalize_config` writes those as `(object)[]` - php's only
  unambiguous empty map - and `validate_config` returns the plain-array
  form. **The one behaviour this port cannot match: a station.json
  written with an explicitly empty `"profiles": {}` (or an empty
  profile-level `feature`/`api`/`sdk` map) is indistinguishable from an
  empty list and is rejected by the shape.** Omit the key instead -
  `{"station": 1}` is the documented spelling and validates clean.
  `canonical_serialize` carries the same variance: an empty map that
  arrived as a PHP array emits `[]`, while a deliberate `(object)[]`
  keeps `{}`.
- Value semantics also make copy-on-inject (design station.md 5.3) hold
  by construction - the middleware still swaps only its own copy.
- **The loader (design 6.3) resolves through CLASS AUTOLOADING**, which
  is php's "ordinary resolution from the application root": there is no
  runtime module import, so `api.<slug>.package` names the SDK
  package's root NAMESPACE (a composer package name is camelized into
  one, `acme/stripe-sdk` -> `Acme\StripeSdk`), and the loader asks the
  registered autoloaders for `<package>\SDK`, then the derived
  `<Camel>SDK`, then whatever `export` names. Self-registration (6.2
  path 1) is Composer's `autoload.files`: a generated package whose
  entry file calls `Voxgig\Station\provide()` has registered itself
  before station runs. `check_package`'s rules are enforced either way -
  module names only, never a path, a URL or a traversal segment.
- **`load()` is synchronous.** php has one module system and no async,
  so there is no ESM split to accommodate: `load()` preloads every
  declared active instance's package and `sdk()` was synchronous all
  along. `Station::open(['load' => false])` makes it inert.
- **`warm()` resolves serially** over the DEDUPLICATED secret names -
  php has no async idiom, so concurrency is not available. The
  deduplication is the half that matters: the broker's resolution cache
  is keyed by secret name, so several instances sharing one api-level
  `secret` cost one round-trip either way.
- `options()` takes an OPTIONAL LEADING instance name -
  `options($extra)` and `options($name, $extra)` are the same method, so
  every existing call is unchanged.
- Process-per-request runtimes run solo by default (design station.md
  3.4); the attached-mode rejoin handshake arrives with the proxy.
