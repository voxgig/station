# station - Lua

Lua 5.3+/5.4 port of the station library core (solo mode). A port of
the canonical TypeScript implementation (`typescript/src/`); behaviour
must match, case for case, through the shared conformance corpus
(`spec/station.json`, run via [voxgig/omni](https://github.com/voxgig/omni)).

One module, one file: `src/voxgig_station.lua`. That is deliberate -
generated Lua SDKs receive this library **vendored** (there is no
`voxgig-station` rock yet, and a rockspec dependency on a nonexistent
package would break every consumer install). The sdkgen-station package
carries the vendored copy at
`sdkgen-station/.sdk/tm/lua/feature/station/voxgig_station.lua`; the
copy here is canonical. Edit here first, then refresh the vendored copy
byte-identically.

## Env-only secrets, and it says so

There is no sekreto Lua port (design station.md §2.2), so this library
resolves secrets from **the process environment only**, read directly
under the envkey of the secret name -
`voxgig_solardemo.apikey` → `VOXGIG_SOLARDEMO_APIKEY`, the same mapping
sekreto's `envkey()` defines and the env var generated SDKs already
document. A profile whose provider chain names any other store gets a
warning event at `open()` (and `status().secrets == 'env-only'`), not a
silent partial implementation. The permanent fix is a sekreto Lua port,
contributed to sekreto.

## Use

```lua
local station = require('voxgig_station')

local st = station.open()                     -- profile/env defaulted; solo
local sdk = st:connect(TaskpadSDK)            -- was: TaskpadSDK.new({ apikey = ... })
-- or, inverted binding:
local sdk2 = TaskpadSDK.new(st:options({ base = 'http://localhost:8901' }))

local untap = st:tap(print)                   -- live events
print(st:canonical_descriptor('taskpad'))     -- byte-stable descriptor v1
```

The SDK-facing seams follow the generated Lua SDKs' conventions: the
transport middleware returns the `(res, err)` multi-return pair, client
mode is `client.mode`, per-op correlation rides the `station$` slot on
the SDK's own ctx, and the adapter is a duck-typed feature table whose
hook methods are found by literal name.

Because Lua tables cannot hold nil and cannot tell an empty list from an
empty map, the module carries `station.NULL` plus `station.map{}` /
`station.list{}` taggers (the dkjson `__jsontype` metatable convention),
and the canonical serializer sorts keys itself - `pairs()` order is
never trusted (design station.md §4).

## Test

```sh
make test           # unit suite + conformance corpus
lua5.4 test/station.lua
lua5.4 test/conform.lua       # needs a sibling omni checkout or OMNI_HOME
```
