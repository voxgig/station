# station — Python

The Python port of [station](../README.md): one control surface for
outbound integrations. A port of `typescript/src/`, which is canonical.

```sh
make test                     # conformance corpus + unit suite
```

```py
from voxgig_station import Station
from taskpad_sdk import TaskpadSDK

station = Station.open()          # profile/env all defaulted
pad = station.connect(TaskpadSDK) # was: TaskpadSDK({"apikey": ...})

todos = list(pad.Todo().list())
```

…or declaratively, from `station.json` — one call per instance, no
constructor arguments anywhere:

```py
station = Station.open()
Station.provide('taskpad', {'construct': TaskpadSDK, 'config': CONFIG})

pad = station.sdk('taskpad')        # constructed on first ask, cached
eu = station.sdk('taskpad$eu')      # a second instance of one api
report = station.check()            # every active instance, in CI
```

Solo mode only (the proxy client is deferred with the proxy itself):
`proxy: "require"` fails operations with `station_no_proxy`, and `auto`
degrades to solo with one warning event. Synchronous throughout — the
generated py SDKs are synchronous and their transport seam returns
`(response, err)` tuples, so the middleware does too.

Secrets resolve through [voxgig/sekreto](https://github.com/voxgig/sekreto)'s
Python port (`voxgig-sekreto`); the SDK's `options["apikey"]` holds only
the `[station:<instance>]` placeholder and the middleware swaps the real
value in at send time, into a copied fetchdef (copy-on-inject —
`ctrl.explain`/`ctx.spec` never see the value).

The config grammar validates through the Python port of
[voxgig/struct](https://github.com/voxgig/struct), which
`voxgig_station/structhome.py` finds as a sibling checkout (set
`STRUCT_HOME` if yours is elsewhere — the same convention as omni
below). Unlike omni this is a **runtime** dependency: `validate_config`
runs at `open()`, not just under test. sekreto and struct are the only
two, and there will be no third.

## Layout

| | |
|---|---|
| `voxgig_station/station.py` | `Station` — open/connect/adopt/options, `sdk`/`create`/`check`/`warm`, the registry, the transport middleware, the ref grammar |
| `voxgig_station/adapter.py` | `feature_binding` (both entry paths) + the carried adapter for `connect`/`adopt` |
| `voxgig_station/shape.py` | `normalize_config`/`validate_config`: the §4 grammar, the §4.4 workarounds, the §5.2 credential scans |
| `voxgig_station/feature.py` | the §8 three-level merge, the order resolver, the descriptor-derived checker |
| `voxgig_station/factory.py` | the process-global factory table (`provide`, §6.2) |
| `voxgig_station/loader.py` | `load_sync`: `importlib` by module name, behind `check_package` (§6.3) |
| `voxgig_station/descriptor.py` | descriptor normalizer, canonical serializer, `envtoken`/`secretname_default` |
| `voxgig_station/secrets.py` | the sekreto-backed broker: miss vs error, exact-value scrub (no length floor) |
| `voxgig_station/profile.py` | `station.json` lookup, config scope, profile selection + merge (providers replace wholesale) |
| `voxgig_station/structhome.py` | locates the sibling voxgig/struct checkout |
| `voxgig_station/events.py` | the bounded ring + tap |
| `voxgig_station/error.py` | the pinned error-code catalog |
| `tests/test_conform.py` | the 10-section corpus (`spec/station.json`) through the Python voxgig/omni runner |
| `tests/test_station.py` | focused unit tests against a miniature of the py SDK's seams |

## py-specific notes

- The options-borne station handle is a **zero-arg callable** returning
  the instance: the generated SDK's option pipeline (`vs.clone`)
  carries function references but flattens arbitrary objects.
  `feature_binding` accepts the instance, the callable, or falls back
  to `Station.current()`.
- The wrap-position guard counts by feature **name**: the generated
  `_make_feature` falls back to an inert BaseFeature for unknown names,
  so the features list may hold strays and indexes alone prove nothing.
- Mock detection reads the public `client.mode` (`'live'` vs `'test'`),
  not the ts `_mode`.
- **`options()` takes an optional leading instance name** —
  `options(extra)` and `options(name, extra)` — so every existing call
  is unchanged.
- **One module system, so one loader.** py imports by name at runtime,
  so `api.<slug>.package` closes the §6.3 loop and `sdk()` stays
  synchronous. The ts/js CommonJS-vs-ESM split has no counterpart here:
  there is no `load_async`, and `Station.load()` is a **synchronous
  preload** that nothing needs before `sdk()` — it exists so an import
  error is one failure at startup rather than one at first use.
- **`warm()` is serial over the deduplicated secret names**, where
  ts/js resolve them concurrently: this port is synchronous throughout
  and so is sekreto's py port, so there is no await to overlap. The
  deduplication is what the method exists for either way — the broker's
  resolution cache is keyed by secret name (§5.3), so several instances
  sharing one api-level `secret` cost one round-trip rather than one
  each.
- `spec/config-shape.json` is read **from the repo at runtime**, not
  mirrored: this port runs from source the way the JavaScript one does,
  so there is no shipped copy to drift. Every `config_shape()` call
  returns a fresh deep copy, because struct's validator consumes the
  spec it walks.

## Testing

`tests/test_conform.py` runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the Python
[voxgig/omni](https://github.com/voxgig/omni) runner. omni and sekreto
are located as sibling checkouts; set `OMNI_HOME` / `SEKRETO_HOME` if
yours live elsewhere.

The suite carries a **completeness guard**: `test_sections_covered`
asserts that the sections it runs (the `DRIVERS` table, from which the
per-section tests are registered) plus its explicit `PENDING` list
exactly cover the sections in the spec file, read as raw JSON. A corpus
section silently not running is a failure, not a gap. One section is
pending — `profile`, which pins the pre-rename `plugin` grammar this
port no longer speaks; everything it pins is restated in the `sdk`/`api`
grammar the `instance` section runs.
