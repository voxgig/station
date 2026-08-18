# station - C++

C++17 header-only port of the station library core (solo mode, tier C).
A port of the canonical TypeScript implementation (`typescript/src/`);
behaviour must match, case for case, through the shared conformance
corpus (`spec/station.json`, run via
[voxgig/omni](https://github.com/voxgig/omni)).

One header, one file: `src/voxgig_station.hpp`. That is deliberate -
generated C++ SDKs receive this library **vendored** (there is no C++
package registry to declare a dependency in; the C++ SDK target is
header-only and registry-less). The sdkgen-station package carries the
vendored copy at
`sdkgen-station/.sdk/tm/cpp/feature/station/voxgig_station.hpp`; the
copy here is canonical. Edit here first, then refresh the vendored copy
byte-identically.

## Tier C scope (design station.md §2.2, §10.1)

Solo mode only - no wire client, no proxy attachment. `proxy: "require"`
fails on the operation path with `station_no_proxy` (§2.1/§14); `auto`
degrades to solo with one warning event. The proxy is a deferred
amplifier, never a required dependency.

## Env-only secrets, and it says so

There is no sekreto C++ port (design station.md §2.2), so this library
resolves secrets from **the process environment only**, read directly
under the envkey of the secret name - `taskpad.apikey` →
`TASKPAD_APIKEY`, the same mapping sekreto's `envkey()` defines and the
env var generated SDKs already document. A profile whose provider chain
names any other store gets a warning event at `open()` (and
`status().secrets == "env-only"`), not a silent partial implementation.
The permanent fix is a sekreto C++ port, contributed to sekreto.

## Design delta, recorded

Station design §3.1 lists inverted binding for static languages and an
`extend`-riding `adopt()` where the SDK's options seam allows it. The
generated **C++ SDK target deliberately does not wire `options.extend`**
(its options are a closed data `Value`, and a feature instance cannot
ride one), so `connect()`/`adopt()` do not exist in this port -
regeneration with the station feature is the only retrofit, exactly as
§3.1 already states for the extend-less targets (c, zig, haskell,
ocaml, lean); cpp belongs on that list. Binding forms here:

- **Inverted binding** - `st->options(extra)` returns the plain options
  `Value` the generated constructor already accepts, with the
  `feature.station.active` entry merged in.
- **Ambient-only handle** - a C++ options map cannot carry an instance
  pointer through the generated clone/merge/validate pipeline, so the
  generated `StationFeature` binds to `Station::current()` (the ambient
  instance `Station::open()` created). Isolated `Station` instances
  (plain construction) never bind SDKs; they exist for tests.

## Use (inside a generated SDK with the station feature)

```cpp
#include "core/sdk.hpp"   // the generated SDK (vendors this library)

auto st = vstation::Station::open();          // profile/env defaulted; solo
TaskpadSDK sdk(st->options());                // was: TaskpadSDK({apikey: ...})

auto untap = st->tap([](const vstation::Jval& ev) {
  std::cout << vstation::canonical_serialize(ev) << "\n";
});
sdk.Todo()->list(Value::undef(), Value::undef());
std::cout << st->canonical_descriptor("taskpad") << "\n";
```

The SDK-facing seams follow the generated C++ SDK's conventions: the
transport middleware **throws `SdkErrorPtr`** on failure (and catches/
rethrows to observe - the C++ SDK convention), client mode is
`client->mode`, per-op correlation rides an id-guarded `station$` slot
on the SDK ctx's `shared` map, and the adapter is a `BaseFeature`
subclass (`StationFeature`) whose hook overrides delegate here. The
SDK-coupled half of the header compiles only when the generated SDK's
`core/types.hpp` include guard is visible; standalone (tests, corpus)
the self-contained core compiles alone.

## Test

```sh
make test            # unit suite + conformance corpus (needs sibling omni)
./build/unit         # unit suite only
./build/conform      # corpus only (7 sections)
OMNI_HOME=/path/to/omni make test
```
