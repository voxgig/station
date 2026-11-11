# station - C

C port of the canonical TypeScript implementation. **Tier C** (design
station.md §2.2): solo mode only - no wire client, no proxy attachment;
secrets resolve through **sekreto's C port**, vendored at
`vendor/sekreto` (see **Secrets** below); **no `station.json` file
lookup** - configuration arrives in code (`vxstn_open` takes the config
JSON), which keeps the vendored surface small (design §10.1). A consumer
that reads `station.json` itself passes the text.

```sh
make test          # check-core, then the unit, conformance and secret-store suites
make asan          # the same suites, everything rebuilt with AddressSanitizer and UBSan
make valgrind      # the same suites under Valgrind
```

Builds with `-Wall -Wextra -Werror`. The conformance suite needs a
sibling `voxgig/omni` checkout (or `OMNI_HOME`); the library itself
needs sibling `voxgig/struct` and `voxgig/plugin` checkouts (or
`STRUCT_HOME`, `PLUGIN_HOME`); the secret-store suite links libcrypto -
see **Dependencies** below.

## Use

The library is C99 + POSIX (`getenv`, `clock_gettime`), one public
header plus five sources over the vendored sekreto, designed to be
**vendored into a generated C SDK** by the `@voxgig/sdkgen-station`
package (C has no
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
vxstn_val* status = vxstn_status(st);          /* mode, profile, plugins, drops */
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

## Secrets

The profile's `secrets.providers` chain goes to sekreto verbatim, as in
every other sekreto port, and `[{ "kind": "env" }]` is its default, so a
config that names no chain reads the environment under the envkey of the
secret name exactly as before. The four built-in kinds - `env`,
`memory`, `dotenv` and `file` - need nothing more. A plugin kind resolves
only when the application links it and hands its definition over, which
is sekreto's own rule; `minivault` is the one this port vendors:

```c
#include "voxgig_station.h"
#include "sekretoplugins.h"   /* vendor/sekreto/plugins */

void* plugins[] = { sek_plugin_minivault() };
vxstn_open_opts opts = {0};
opts.config_json = config;    /* built in memory: the passphrase rides the provider spec */
opts.plugins = plugins;
opts.plugincount = 1;
vxstn_station* st = vxstn_open(&opts, &err);
```

with a chain such as
`[{"kind":"minivault","file":"app.skmv","passphrase":"..."}]` and a link
line that adds `minivault.c`, `encode.c` and `-lcrypto`. A chain naming a
kind that was not handed in fails `vxstn_open()` with
`station_secret_error` and sekreto's refusal, which names the kind and
the `plugins` option. A store that cannot answer - a wrong passphrase, a
missing vault file - fails the lookup with `station_secret_error` and
never falls through to the store behind it. Whatever the chain says, the
station core links no crypto; `make check-core` reads that off the built
artifacts.

`VXSTN_ENV_ONLY` builds the broker to read the process environment
directly, with no sekreto at all. The sdkgen-station payload is built
that way, because a generated C SDK compiles sekreto only while its own
`secrets` feature is active. That build reports `secrets: "env-only"` in
`status()`, and a chain naming any other store gets a warning event at
open. `make test` runs the unit suite in both builds.

## Dependencies

Two, and both are stated in the design (§4, §9, §10): **voxgig/sekreto**,
which resolves secrets, and **voxgig/struct**, which validates the config
grammar. Both are RUNTIME dependencies, not test ones, and C has no
registry, so both are VENDORED:

- sekreto's C core and its mini vault are carried in `vendor/sekreto`,
  read out of git at one sekreto commit and stamped with it by
  `tools/vendor.py` (`make vendor-refresh`; `make vendor-check` fails on
  drift). sekreto's core is built on **voxgig/plugin**'s C host, which
  this checkout finds as a sibling: `$PLUGIN_HOME`, then `../../plugin`,
  then two fixed fallbacks. The mini vault needs the platform's
  libcrypto, as sekreto's plugins do; the core needs none.
- struct is the one a generated C SDK already carries, at
  `utility/struct/` beside this library's own `feature/station/` (the
  precedent sdkgen-station's `.sdk/tm/c/feature/station/VENDORED.md`
  names), and this checkout borrows the sibling: `$STRUCT_HOME`, then
  `../../struct`, then two fixed fallbacks.

Each dependency is compiled on ITS OWN include path and with its own
flags - struct ships `src/regex.h` and omni's `util.c` wants POSIX's
`<regex.h>`, so one shared command line breaks the other's build.

No other dependency is added, here or anywhere else in this port.

## Layout

| File | Contents |
|---|---|
| `src/voxgig_station.h` | the public API and the scope statement |
| `src/voxgig_station_int.h` | internal helpers shared by the five sources (string builder, map reads, sorted keys) and the secret store's interface - not public API |
| `src/voxgig_station.c` | the core: value model + JSON, canonical serializer, identity (envtoken/secretname), descriptor normalizer, profile resolution, event ring/taps, the secret broker, the instance registry, and the declarative front door |
| `src/voxgig_station_secrets.c` | design §5: the store the broker asks - sekreto's chain, or the environment when built with `VXSTN_ENV_ONLY` |
| `src/voxgig_station_shape.c` | design §4: `vxstn_normalize_config` (the defaults materializer) and `vxstn_validate_config` (the shape run through voxgig/struct, plus the §4.4 and §5.2 scans) |
| `src/voxgig_station_feature.c` | design §8: the three-level feature merge, the constraint-and-band order, the station pin, and the descriptor-derived option checker |
| `src/voxgig_station_factory.c` | design §6.1/§6.2: the instance ref grammar and the process-global factory table |
| `src/config_shape.h` | GENERATED - a verbatim mirror of `spec/config-shape.json` (`make sync-shape`) |
| `tools/sync-shape.py` | regenerates that mirror |
| `vendor/sekreto/` | VENDORED - sekreto's C core and the mini vault plugin, at the commit their stamps name (`VENDORED.md` there) |
| `test/unit.c` | focused unit tests (ring, broker, ambient, register, wrap order, policy, and the whole Stage 5 surface) plus the shape drift guard |
| `test/conform.c` | the shared corpus (`spec/station.json`) through the omni C runner |
| `test/secrets.c` | the secret-store suite: a real mini vault written to a scratch directory and read with its passphrase in memory, plus the file-backed built-in kinds; links libcrypto |
| `test/checkcore.sh` | the link discipline, read off the built artifacts (`make check-core`) |
| `test/leaks.supp`, `test/valgrind.supp` | the one leak the sanitizer and Valgrind runs of the secret-store suite accept: struct's validator, at open |

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
- **Plugin kinds are handed in, never all linked.** The dynamic ports give
  sekreto its whole plugin set; in C that set would link every plugin's
  TLS and crypto into every binary, so a chain may name a plugin kind
  only when the application links it and passes its definition in
  `vxstn_open_opts.plugins` - sekreto's own C rule. This port vendors the
  mini vault, and another kind is the same shape.
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
  byte-identical at `.sdk/tm/c/feature/station/`, apart from the
  `VXSTN_ENV_ONLY` define its copy of `voxgig_station_int.h` carries;
  its SDK Makefile compiles `feature/*/*.c` by wildcard, so every source
  rides along, and `VENDORED.md` there lists them. Edit here
  first, then `make vendor-refresh` from the repo root; `make
  vendor-check` fails on drift and runs in CI.
