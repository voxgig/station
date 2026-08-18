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

Solo mode only (the proxy client is deferred with the proxy itself):
`proxy: "require"` fails operations with `station_no_proxy`, and `auto`
degrades to solo with one warning event. Synchronous throughout — the
generated py SDKs are synchronous and their transport seam returns
`(response, err)` tuples, so the middleware does too.

Secrets resolve through [voxgig/sekreto](https://github.com/voxgig/sekreto)'s
Python port (`voxgig-sekreto`, the library's one dependency); the SDK's
`options["apikey"]` holds only the `[station:<slug>]` placeholder and the
middleware swaps the real value in at send time, into a copied fetchdef
(copy-on-inject — `ctrl.explain`/`ctx.spec` never see the value).

## Layout

| | |
|---|---|
| `voxgig_station/station.py` | `Station` — ambient instance, registry, transport middleware, events surface |
| `voxgig_station/adapter.py` | `feature_binding` (both entry paths) + the carried adapter for `connect`/`adopt` |
| `voxgig_station/descriptor.py` | descriptor normalizer, canonical serializer, `envtoken`/`secretname_default` |
| `voxgig_station/secrets.py` | the sekreto-backed broker: miss vs error, exact-value scrub (no length floor) |
| `voxgig_station/profile.py` | `station.json` lookup, profile selection + merge (providers replace wholesale) |
| `voxgig_station/events.py` | the bounded ring + tap |
| `voxgig_station/error.py` | the pinned error-code catalog |
| `tests/test_conform.py` | the 7-section corpus (`spec/station.json`) through the Python voxgig/omni runner |
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

## Testing

`tests/test_conform.py` runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the Python
[voxgig/omni](https://github.com/voxgig/omni) runner. omni and sekreto
are located as sibling checkouts; set `OMNI_HOME` / `SEKRETO_HOME` if
yours live elsewhere.
