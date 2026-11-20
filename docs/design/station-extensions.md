# Extensions: voxgig/plugin definitions a Station hosts

**Status:** typescript, since W8.6, and its two extension points since
W9.1. The owner asked for it on 2026-11-14 (D-2026-11-14-1). The first
two extensions are voxgig/station-view, which shows an SDK's traffic on
a local page (W9.5), and voxgig/station-mcp, which serves its
operations over MCP (W9.4).

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
   shared by every port. It raises three of plugin's itself:
   `plugin_ref_reserved` for an extension named `station`;
   `plugin_ref_duplicate` for a second, different definition under a
   name in use; and `plugin_bad_name` for a name `Object.prototype`
   holds, such as `constructor`, which plugin 0.2.0's host cannot store
   (`plugin-7`). `use()` with the same definition again does nothing. A
   closed Station takes no extension: `use()` raises
   `station_no_plugin`, as `connect()` and `sdk()` do.
5. **The public API, and nothing else.** An extension holds the Station
   itself, so it can call what any caller can. No secret value is
   reachable that way: events are scrubbed before they are buffered,
   and `status()`, `instances()` and `events()` carry no resolved
   value.
6. **Teardown.** `close()` closes the extension host first, which takes
   every extension down in reverse ref order: `deactivate`, then its
   releases, newest first, then `close`.

## Two extension points

The Station's plugin host declares two points an extension can bind in
its `define`:

```ts
import { BOUND_POINT, FEATURE_POINT, withfeature } from '@voxgig/station'

export const Watch = {
  name: 'watch',
  define(inst) {
    inst.bind(FEATURE_POINT, (next, feature, info) =>
      next(withfeature(feature, 'telemetry',
        { active: true, exporter: (span) => keep(span) }, info.descriptor), info))
    inst.bind(BOUND_POINT, ({ name, api, descriptor, client }) => hold(name, client))
  },
}
```

- **`sdk.feature`** is a chain. Before the Station constructs an SDK it
  passes the caller's feature collection through every binding, in
  sdkgen's map form or its list form as the caller wrote it, with what
  the Station knows of the SDK: `{ name, api, descriptor }`. That
  happens for `connect()`, `adopt()`, `sdk()` and `create()`, and in
  `options()` for a caller who constructs the SDK itself. A binding
  returns `next(feature, info)`, amended. It sees neither the rest of
  the options, which can hold the caller's key, nor station's own
  entry, which joins the collection afterwards in its pinned place.
- **`sdk.bound`** is a hook. Each client the Station binds is told to
  every binding, as `{ name, api, descriptor, client }`.

Five rules go with them:

1. **The descriptor is there when the Station knows the API before
   construction.** It does on the declarative paths, and for a
   `connect()` that names its instance. An unnamed `connect()` learns
   its API from the SDK's own config during construction, so its
   bindings get `{}`.
2. **An SDK is never handed a feature it was not generated with**,
   because a generated constructor fails on an active feature it has no
   class for. `withfeature` checks the descriptor's `features`, and
   leaves the collection as it was when the feature is not there, or
   when there is no descriptor.
3. **The caller's settings win.** `withfeature` lays the extension's
   entry under the caller's. Where both set a function, the caller's
   runs first and its result stands, and the extension's runs after it
   and cannot fail the SDK's call. A caller who switched a feature off
   keeps it off.
4. **An extension cannot break construction.** A binding that throws at
   `sdk.feature` leaves the collection as the caller gave it. One that
   throws at `sdk.bound` does not stop the others, because the hook runs
   in plugin's `serial` mode, which collects errors. Each failure is a
   `station` event with a warning: `an extension failed at sdk.feature:
   …`.
5. **The client is still being constructed** when `sdk.bound` is told
   of it: the Station binds it from inside the SDK's constructor. An
   extension keeps it for later. It learns only of clients bound after
   its `use()`, so a caller uses extensions before building SDKs.

## Three things plugin 0.2.0 decides

- **The `station` ref is not reserved through plugin.** A host can
  reserve a name with `makehost({ reserved })`, but in 0.2.0 an
  instance the host declares under a reserved name cannot then be
  activated: `activate` reloads it through `declare`, which checks the
  reserved list again without the host-owned flag (`plugin-6` in
  `upstream.md`). Station declares its own instance as an ordinary one
  and refuses the name in `use()`.
- **Names `Object.prototype` holds.** The host keeps its instances in a
  plain object, so `declare` finds `Object.prototype.constructor` for an
  instance named `constructor`, and fails with a `TypeError`
  (`plugin-7`). plugin's name grammar accepts seven such names. Station
  refuses all seven before the host sees one.
- **Two copies of plugin.** sekreto 0.3.0 takes `@voxgig/plugin`
  `^0.1.3`, and station `^0.2.0`, so an install holds both
  (`sekreto-7`). The two hosts never meet, so nothing crosses between
  the copies.

## station-view and station-mcp

- **station-view** exports `view`. Its `snapshot()` reads the
  Station's status, instances and events, and since W9.5 its `listen()`
  serves the traffic as a page, a read-only JSON API and a server-sent
  stream, on loopback only. Through `sdk.feature` it switches on
  `telemetry`, `debug`, `audit` and `metrics` in each SDK generated with
  them. That is one process's traffic, one of the two sources
  D-2026-11-11-5 left open. The other is the proxy's `/v1/status`,
  `/v1/tap` and `/v1/traffic`, for when attach has shipped.
- **station-mcp** exports `mcp`, whose `tools()` and `call()` answer
  two of the proxy's tools, `station_status` and
  `station_integrations`, from the Station's public API. Since W9.4 it
  also serves sdkgen go-mcp's tool shape for each SDK `sdk.bound`
  reports, the write tools only with `{ write: true }`, over JSON-RPC in
  process and on stdio; streamable HTTP is not done. The design puts
  the agent surface in the proxy (`station.md` §7), where no SDK code
  runs. An extension runs in the application's process, so it does not
  have that property. Whether station-mcp's real surface is served from
  there or relayed to the proxy's `/v1/mcp` is the question
  D-2026-11-14-1 leaves open.

## Ports

typescript first, then javascript, the other npm route, then the rest
as W8 reaches them. W8.1's note, on replacing station's native ref,
config, lifecycle and order code with plugin's, is still to be written.
This note covers extension hosting only.
