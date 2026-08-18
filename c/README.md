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
sibling `voxgig/omni` checkout (or `OMNI_HOME`).

## Use

The library is standalone C99 + POSIX (`getenv`, `clock_gettime`), one
header + one source, designed to be **vendored into a generated C SDK**
by the `@voxgig/sdkgen-station` package (C has no package registry;
design §9.2). The generated `feature/station.c` adapter is the SDK-side
bridge; every decision it enforces - wrap order, host policy, secret
resolution, event shapes - lives here.

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

## Layout

| File | Contents |
|---|---|
| `src/voxgig_station.h` | the public API and the scope statement |
| `src/voxgig_station.c` | the whole library: value model + JSON, canonical serializer, identity (envtoken/secretname), descriptor normalizer, profile resolution, event ring/taps, env-only broker, Station |
| `test/unit.c` | focused unit tests (ring, broker, ambient, register, wrap order, policy) |
| `test/conform.c` | the 7-section shared corpus (`spec/station.json`) through the omni C runner |

## Notes

- The corpus sections a tier-C library cannot honestly run (`envelope`,
  attached `degrade` - wire-dependent, tiers A/B only per design §13)
  are out of scope here, not faked; `spec/station.json` currently
  carries the pure-contract sections, and all of them run.
- Memory: plain `malloc`; owned-return discipline documented per
  function in the header. Inside a generated C SDK (a never-free host)
  leaking short-lived station values matches the host's discipline.
- Threading: none - the generated C SDKs are single-threaded and the
  library matches that scope (see the header).
- **Copies**: the sdkgen-station package vendors
  `src/voxgig_station.{h,c}` byte-identical at
  `.sdk/tm/c/feature/station/`. Edit here first, then refresh the
  vendored copy.
