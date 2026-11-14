# Extensions: voxgig/plugin definitions a Station hosts

**Status:** typescript, since W8.6. The owner asked for it on
2026-11-14 (D-2026-11-14-1). The first two extensions,
voxgig/station-view and voxgig/station-mcp, are stubs.

## What an extension is

An extension is a [voxgig/plugin](https://github.com/voxgig/plugin)
definition that a caller hands to a Station:

```ts
import { Station } from '@voxgig/station'
import { StationView } from '@voxgig/station-view'

const station = new Station({ profile: 'default' }).use(StationView)

station.extensions()            // [{ name: 'view', status: 'live' }]
station.extension('view/view')  // what the extension exported
station.close()                 // takes every extension down first
```

The Station keeps a voxgig/plugin host of its own. Its first instance
is the Station itself, exported as `station/station`. An extension
reads it there, in its `activate`:

```ts
export const Probe = {
  name: 'probe',
  activate(inst) {
    const station = inst.host().exports('station/station')
    inst.export('probe', { mode: station.status().mode })
  },
}
```

Station calls them extensions because "plugin" already means a bound
SDK here (`station.md` §3): `plugins()`, `status().plugins` and
`station_no_plugin` are all about SDKs, and an extension appears in none
of them.

## The rules

1. **Loading is explicit.** A Station loads only what a caller hands to
   `use()`, as sekreto loads only the plugins its constructor is given.
   Nothing is loaded because a package is installed. `station.json`
   does not name extensions either: a key there would change the
   grammar every port reads, and `plugin` is already a refused key
   (`station-declarative-config.md` §1).
2. **Not an option.** A definition carries functions, so it stays out
   of `StationOptions`, which `Station.open()` compares as JSON.
3. **Synchronous.** voxgig/plugin's host is synchronous. `use()` returns
   once the extension is live, or throws with it failed. An extension
   that starts something asynchronous holds it with `inst.release`. A
   failure after activation does not change its status.
4. **Plugin's errors.** A failing definition raises voxgig/plugin's
   `PluginError`, with plugin's codes (`plugin_activate_failed` and the
   rest). Station adds no code of its own, because its error catalog is
   shared by every port. It raises two of plugin's itself:
   `plugin_ref_reserved` for an extension named `station`, and
   `plugin_ref_duplicate` for a second, different definition under a
   name in use. `use()` with the same definition again does nothing.
5. **The public API, and nothing else.** An extension holds the Station
   itself, so it can call what any caller can. No secret value is
   reachable that way: events are scrubbed before they are buffered,
   and `status()`, `instances()` and `events()` carry no resolved
   value.
6. **Teardown.** `close()` closes the extension host first, which takes
   every extension down in reverse ref order: `deactivate`, then its
   releases, newest first, then `close`.

## Two things plugin 0.2.0 decides

- **The `station` ref is not reserved through plugin.** A host can
  reserve a name with `makehost({ reserved })`, but in 0.2.0 an
  instance the host declares under a reserved name cannot then be
  activated: `activate` reloads it through `declare`, which checks the
  reserved list again without the host-owned flag (`plugin-6` in
  `upstream.md`). Station declares its own instance as an ordinary one
  and refuses the name in `use()`.
- **Two copies of plugin.** sekreto 0.3.0 takes `@voxgig/plugin`
  `^0.1.3`, and station `^0.2.0`, so an install holds both
  (`sekreto-7`). The two hosts never meet, so nothing crosses between
  the copies.

## station-view and station-mcp

- **station-view** exports `view`, whose `snapshot()` reads the
  Station's status, instances and events. That is one process's
  in-memory event ring, one of the two sources D-2026-11-11-5 left
  open. The other is the proxy's `/v1/status`, `/v1/tap` and
  `/v1/traffic`, for when attach has shipped.
- **station-mcp** exports `mcp`, whose `tools()` and `call()` answer
  two of the proxy's tools, `station_status` and
  `station_integrations`, from the Station's public API. It has no
  transport. The design puts the agent surface in the proxy (`station.md`
  §7), where no SDK code runs. An extension runs in the application's
  process, so it does not have that property. Whether station-mcp's
  real surface is served from there or relayed to the proxy's
  `/v1/mcp` is the question D-2026-11-14-1 leaves open.

## Ports

typescript first, then javascript, the other npm route, then the rest
as W8 reaches them. W8.1's note, on replacing station's native ref,
config, lifecycle and order code with plugin's, is still to be written.
This note covers extension hosting only.
