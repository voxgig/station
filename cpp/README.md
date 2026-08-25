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

## Dependencies

**voxgig/struct is a RUNTIME dependency** (design station.md §4, §9),
and the only one. `validate_config` runs at `open()`, not just under
test, and validation is struct's - `validate` with an `errs` collection
so it COLLECTS rather than throwing at the first problem, closed maps by
default, and `` `$OPEN` `` where a foreign grammar passes through - not
a second validator written here.

C++ has no registry, so struct is **vendored** exactly as this library
is: a generated C++ SDK already carries it (the SDK's own
`utility/voxgigstruct/`, the precedent this library's `VENDORED.md`
names) beside `feature/station/`. Both are header-only, so there is
nothing to link. In THIS checkout the Makefile finds a sibling the way
every port finds its siblings: `$STRUCT_HOME`, then `../../struct`, then
two fixed fallbacks. It is put on the include path with `-isystem`, for
the same reason the C port compiles struct with struct's own flags:
`-Werror` over somebody else's warnings is a build that breaks on their
next release.

Secrets are **env-only** and it says so - see below. Nothing else is
taken.

### One recorded workaround, in `pin_spec_names`

Canonical struct lowers a spec term's `` `$NAME` `` to a bare `name`
across the whole joined description, so a `$ONE` failure reads
`[exact,library]`. The **C++ port of struct applies that only to a
top-level string term**, so a nested list or map term keeps its
backticked names. Five corpus entries pin the canonical spelling, so
this port finishes the replacement itself, over canonical's own scope
and no wider. Remove it when struct's C++ port lowers the joined
description - those corpus entries are what will say so.

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

One consequence, stated rather than hidden: `warm()` resolves the
**deduplicated** secret-name set **serially**. The canonical resolves
one per distinct name concurrently because a provider round-trip
dominates; here a resolution is a `getenv` and there is nothing to
overlap. The deduplication itself is not optional - the broker's
resolution cache is keyed by secret name, so several instances sharing
one api-level `secret` cost one lookup.

## Design deltas, recorded

### No `connect()`/`adopt()` - no `extend` seam

Station design §3.1 lists inverted binding for static languages and an
`extend`-riding `adopt()` where the SDK's options seam allows it. The
generated **C++ SDK target deliberately does not wire `options.extend`**
(its options are a closed data `Value`, and a feature instance cannot
ride one), so `connect()`/`adopt()` do not exist in this port -
regeneration with the station feature is the only retrofit, exactly as
§3.1 already states for the extend-less targets (c, zig, haskell,
ocaml, lean); cpp belongs on that list. Binding forms here:

- **Inverted binding** - `st->options(extra)`, or
  `st->options(instance, extra)` when the construction registers under
  a named instance, returns the plain options `Value` the generated
  constructor already accepts. C++ cannot overload on a *leading*
  optional argument the way the canonical `options(instanceName?,
  extra?)` does, so the name gets its own overload and every existing
  `options({...})` call is unchanged. The declarative path's Jval
  spelling of the same map is `st->options_for(instance, extra)`.
- **Ambient-only handle** - a C++ options map cannot carry an instance
  pointer through the generated clone/merge/validate pipeline, so the
  generated `StationFeature` binds to `Station::current()` (the ambient
  instance `Station::open()` created). Isolated `Station` instances
  (plain construction) never bind SDKs; they exist for tests.

### `package` is in the grammar and is not honoured here (§6.2/§6.3)

Of the three ways the factory table gets filled, **this port offers
exactly one**: `vstation::provide(api, {construct, config})` (or
`Station::provide`), called by the application - or by a generated C++
SDK's own registrar - before the first `sdk()`.

- **Self-registration is not available.** A header-only library vendored
  into a static C++ SDK has no module-init hook a linker is required to
  run.
- **The loader does not exist.** C++ has no import-by-name at run time
  at all, so `loadSync`/`loadAsync`/`factoryFromModule` are absent,
  `load()` is present and inert, and `StationOptions{load = false}` is
  accepted and equally inert.
- **`package` and `export` stay IN THE GRAMMAR**: they are shape keys,
  the corpus validates configs carrying them, and removing them would
  break one-config-file-serves-a-polyglot-fleet. They are ignored at
  runtime with **one warning event per api at `open()`**, never an
  error.
- `check_package()` is still implemented, as the pure validator it is,
  and raises the same `station_sdk_load` message every loader port
  raises - so a config shared with a loader port fails the same way in
  both. Nothing in this port ever imports anything.
- `station_sdk_load` stays in the error catalog (the `errors` corpus
  section pins all 29 codes for every port) and is raised only by that
  validator.
- `resolve_factory` therefore has TWO paths - the registered factory,
  then the error - and the `station_no_factory` message names only the
  remedies this port actually offers.

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

The declarative front door (design §6), for a `station.json` that
declares its instances:

```cpp
vstation::Factory factory;
factory.config = TASKPAD_CONFIG;              // the generated config constant
factory.construct = [](const vstation::Jval& options) -> std::shared_ptr<void> {
  return std::make_shared<TaskpadSDK>(to_sdk_value(options));
};
vstation::Station::provide("taskpad", factory);

auto st = vstation::Station::open();
auto client = std::static_pointer_cast<TaskpadSDK>(st->sdk("taskpad$eu"));

auto report = st->check();                    // one CI failure, not twenty
auto warmed = st->warm();                     // batch-resolve the credentials

vstation::Station::FeatureFilter want;        // "is debug on anywhere?"
want.feature = "debug";
for (const auto& row : st->features(want)) {
  std::cout << row.instance << " " << vstation::canonical_serialize(row.from) << "\n";
}
```

A factory's client is a `std::shared_ptr<void>` because a station
library cannot name the generated SDK's type - the same opaque identity
the binding seam already crosses with.

The SDK-facing seams follow the generated C++ SDK's conventions: the
transport middleware **throws `SdkErrorPtr`** on failure (and catches/
rethrows to observe - the C++ SDK convention), client mode is
`client->mode`, per-op correlation rides an id-guarded `station$` slot
on the SDK ctx's `shared` map, and the adapter is a `BaseFeature`
subclass (`StationFeature`) whose hook overrides delegate here. The
SDK-coupled half of the header compiles only when the generated SDK's
`core/types.hpp` include guard is visible; standalone (tests, corpus)
the self-contained core compiles alone.

## Layout

| File | Contents |
|---|---|
| `src/voxgig_station.hpp` | the whole library: value model + JSON, canonical serializer, identity (envtoken/secretname), descriptor normalizer, **the config shape mirror + `normalize_config`/`validate_config`**, **feature merge/order/checker**, profile resolution, **the instance ref grammar and the factory table**, event ring/taps, env-only broker, **the Station hub and its declarative front door**, and the SDK seam |
| `tools/sync-shape.py` | regenerates the embedded `spec/config-shape.json` mirror (`make sync-shape`) |
| `test/unit.cpp` | focused unit tests (ring, broker, ambient, register, shape mirror + invariants, factory table, declarative front door) |
| `test/conform.cpp` | the shared corpus (`spec/station.json`) through the omni C++ runner |

## The completeness guard

`test/conform.cpp` declares one static table - `DRIVERS` (section →
subject) - and **registers its per-section tests by iterating
`DRIVERS`**, so a section named there cannot silently fail to execute.
The `sections-covered` test then reads `spec/station.json` as raw JSON
(not through the runner, which resolves a named section and would hide
one it never resolved) and asserts that the sections the corpus carries
are **exactly** `DRIVERS`. A section added to the corpus and not picked
up here fails loudly instead of never running; a section renamed or
deleted while this port still lists it fails too.

Ten sections run: the whole corpus, nothing pinned pending.

## Test

```sh
make test            # unit suite + conformance corpus
./build/unit         # unit suite only
./build/conform      # corpus only (10 sections + the guard)
OMNI_HOME=/path/to/omni STRUCT_HOME=/path/to/struct make test
make sync-shape      # after editing spec/config-shape.json
make inspect         # which omni and struct checkouts were found
```

Builds with `-Wall -Wextra -Werror`. The conformance suite needs a
sibling `voxgig/omni` checkout (or `OMNI_HOME`); the library needs a
sibling `voxgig/struct` checkout (or `STRUCT_HOME`).
