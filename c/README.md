# station - C

C port of the canonical TypeScript implementation. **Tier C** (design
station.md §2.2): solo mode only - no wire client, no proxy attachment;
secrets are **env-only** (there is no sekreto C port - the broker reads
the process environment directly under the `envkey` of the secret name,
and says so in `status()` and with a warning event when a profile names
any other store); **no `station.json` file lookup** - configuration
arrives in code (`vxstn_open` takes the config JSON), which keeps the
vendored surface small (design §10.1).

```sh
make test
```

Builds with `-Wall -Wextra -Werror`. The conformance suite needs a
sibling `voxgig/omni` checkout (or `OMNI_HOME`); the library itself
needs a sibling `voxgig/struct` (or `STRUCT_HOME`) - see
**Dependencies** below.

## Use

The library is standalone C99 + POSIX (`getenv`, `clock_gettime`), one
public header plus four sources, designed to be **vendored into a
generated C SDK** by the `@voxgig/sdkgen-station` package (C has no
package registry; design §9.2). The generated `feature/station.c`
adapter is the SDK-side bridge; every decision it enforces - wrap order,
host policy, secret resolution, event shapes - lives here.

```c
#include "voxgig_station.h"

vxstn_error* err = NULL;
vxstn_station* st = vxstn_open(NULL, &err);   /* profile/env defaulted; solo */

/* Inverted binding (design §3.1): the app constructs the SDK through
 * its existing generated constructor with the activation entry
 * options.feature.station.active = true; the generated station feature
 * binds to the ambient instance during construction. */

vxstn_val* events = vxstn_events(st);          /* ring buffer, copied out */
vxstn_val* status = vxstn_status(st);          /* mode, plugins, drops, "env-only" */
char* d = vxstn_canonical_descriptor(st, "taskpad", &err);
vxstn_close(st);
```

### The declarative front door (design §6)

Write the fleet once in the config, register each api's constructor
once, then ask for an instance by name:

```c
vxstn_open_opts opts = {0};
opts.config_json =
  "{\"station\":1,\"profiles\":{\"default\":{"
  "\"sdk\":{\"solar\":{},\"solar$eu\":{\"base\":\"https://eu.solar.example\"}}}}}";
vxstn_station* st = vxstn_open(&opts, &err);   /* validates the config here */

/* The ONLY way an api reaches the factory table in C - see the
 * divergence below. SOLAR_CONFIG is the generated package's own
 * module-level config constant. */
vxstn_provide("solar", solar_construct, NULL, solar_config, &err);

solar_sdk* eu = vxstn_sdk(st, "solar$eu", &err);   /* built once, then cached */
solar_sdk* one = vxstn_create(st, "solar$eu", NULL, &err); /* uncached, auto-tagged */

vxstn_val* report = vxstn_check(st);    /* construct every active instance, for CI */
vxstn_val* view = vxstn_features(st, NULL); /* instance x feature, with provenance */
vxstn_val* warm = vxstn_warm(st, NULL);     /* batch-resolve the fleet's secrets */
```

`vxstn_options(st, name, extra)` is the inverted binding for the same
config: the instance name is the LEADING and OPTIONAL argument (pass
`NULL` for none), because C cannot overload and a second method name
would be a second spelling of one rule.

## Dependencies

Two, and both are stated in the design: **voxgig/sekreto** - which has
no C port, so this tier reads the environment directly and says so - and
**voxgig/struct**, which validates the config grammar (design §4, §9).

struct is a RUNTIME dependency, not a test one: `vxstn_validate_config`
runs at `vxstn_open()`. C has no registry, so it is VENDORED - a
generated C SDK already carries struct at `utility/struct/` beside this
library's own `feature/station/` (the precedent sdkgen-station's
`.sdk/tm/c/feature/station/VENDORED.md` names), and this checkout
borrows the sibling: `$STRUCT_HOME`, then `../../struct`, then two fixed
fallbacks, the same convention the Makefile already uses for omni. Each
dependency is compiled on ITS OWN include path - struct ships
`src/regex.h` and omni's `util.c` wants POSIX's `<regex.h>`, so one
shared command line breaks the other's build.

No third dependency is added, here or anywhere else in this port.

## Layout

| File | Contents |
|---|---|
| `src/voxgig_station.h` | the public API and the scope statement |
| `src/voxgig_station_int.h` | internal helpers shared by the four sources (string builder, map reads, sorted keys) - not public API |
| `src/voxgig_station.c` | the core: value model + JSON, canonical serializer, identity (envtoken/secretname), descriptor normalizer, profile resolution, event ring/taps, env-only broker, the instance registry, and the declarative front door |
| `src/voxgig_station_shape.c` | design §4: `vxstn_normalize_config` (the defaults materializer) and `vxstn_validate_config` (the shape run through voxgig/struct, plus the §4.4 and §5.2 scans) |
| `src/voxgig_station_feature.c` | design §8: the three-level feature merge, the constraint-and-band order, the station pin, and the descriptor-derived option checker |
| `src/voxgig_station_factory.c` | design §6.1/§6.2: the instance ref grammar and the process-global factory table |
| `src/config_shape.h` | GENERATED - a verbatim mirror of `spec/config-shape.json` (`make sync-shape`) |
| `tools/sync-shape.py` | regenerates that mirror |
| `test/unit.c` | focused unit tests (ring, broker, ambient, register, wrap order, policy, and the whole Stage 5 surface) plus the shape drift guard |
| `test/conform.c` | the shared corpus (`spec/station.json`) through the omni C runner |

## The shape mirror

`spec/config-shape.json` is the artifact every port reads. This library
is vendored into a compiled SDK that cannot see `spec/` at run time, and
validation runs at `open()` rather than only under test - so
`src/config_shape.h` embeds the spec file VERBATIM. Re-run
`make sync-shape` after editing the spec; `test/unit.c` compares the
embedded bytes against the file and fails on drift.

Every `vxstn_config_shape()` call returns a FRESH DEEP COPY, because
struct's validator consumes the spec it walks (it deletes satisfied
`$ONE` branches as it goes).

## Conformance, and the completeness guard

`test/conform.c` runs **all ten** of the corpus's sections. The tests
are registered by iterating a `DRIVERS` table rather than written out by
hand, so a section named there cannot silently fail to run; a
`sections-covered` test reads `spec/station.json` as raw JSON - not
through the omni runner, which resolves a named section and would hide
one it never resolved - and asserts that the sections the corpus carries
are EXACTLY `DRIVERS`. A section added to the corpus and not picked up
here fails loudly instead of never running, and a stale driver fails
rather than rotting.

## Divergences

- **No loader (design §6.3, §5.4).** C has no runtime module loading and
  no module-init hook a linker is required to run, so of design §6.2's
  three ways to fill the factory table this port offers exactly ONE:
  `vxstn_provide(api, construct, ud, config, &err)`, called by the
  application (or by a generated SDK's own registrar function) before
  the first `vxstn_sdk()`. Self-registration is NOT available and
  `api.<slug>.package` is NOT honoured - it stays in the grammar,
  because the corpus validates configs carrying it and one config file
  serves a polyglot fleet, but `open()` emits one warning event per
  declared api saying so, and `station_no_factory` names only the
  remedies this port actually offers. `vxstn_check_package` is
  implemented as the pure validator (same `station_sdk_load` message as
  every loader port), so a shared config can be checked here; nothing in
  this port ever imports anything. `station_sdk_load` stays in the
  error catalog - the `errors` section pins all 29 codes for every port
  - but is never raised.
- **No `extend` seam.** The dynamic ports carry the station adapter on
  `extend` so that an SDK generated before the station feature is still
  bound; C has no runtime composition to carry it with, so both the
  imperative and the declarative paths require a regenerated SDK that
  vendors `feature/station.c`. `vxstn_sdk` sets the activation entry
  that feature reads; design §3.1's retrofit case belongs to the ports
  with a loader.
- **`vxstn_warm` resolves serially** over the DEDUPLICATED secret names.
  C has no async idiom; the deduplication is the half that matters here,
  since the broker's resolution cache is keyed by secret name and
  several instances sharing one api-level `secret` must cost one read.
- **`vxstn_options` takes the instance name as a leading, optional
  argument** rather than through an overload, and the station HANDLE
  does not ride the options map: a C value tree holds JSON, not
  pointers, so the generated feature binds to the ambient instance
  (`vxstn_current`) exactly as design §3.1 describes for this tier.
- **The `$CHILD` map-mode message.** struct's C build names the spec key
  in a `$CHILD` type error ("profiles.\`$CHILD\` to be object") where the
  canonical port names the field. The corpus pins the canonical
  spelling, so `vxstn_validate_config` states it itself, beside the
  §4.4 workarounds and for the same reason: the pinned message is
  produced whatever struct build is vendored. Pinned by
  `config#profiles-must-be-a-map` and `config#feature-must-be-a-map`,
  so it is removed deliberately rather than forgotten.
- The corpus sections a tier-C library cannot honestly run (`envelope`,
  attached `degrade` - wire-dependent, tiers A/B only per design §13)
  are out of scope here, not faked; `spec/station.json` currently
  carries the pure-contract sections, and all of them run.

## Notes

- Memory: plain `malloc`; owned-return discipline documented per
  function in the header. Inside a generated C SDK (a never-free host)
  leaking short-lived station values matches the host's discipline.
- Threading: none - the generated C SDKs are single-threaded and the
  library matches that scope (see the header). The factory table is
  process-global by design, so a threaded host calls `vxstn_provide`
  before it starts its threads.
- **Copies**: the sdkgen-station package vendors the library's sources
  byte-identical at `.sdk/tm/c/feature/station/`; its SDK Makefile
  compiles `feature/*/*.c` by wildcard, so the sources added in this
  tranche ride along, and `VENDORED.md` there lists them. Edit here
  first, then refresh the vendored copy.
