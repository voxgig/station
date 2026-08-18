# station — Rust

The Rust port of [station](../README.md): one control surface for
outbound integrations. Hand-written and modem-principle small (design
§10); solo mode only in v1 — the proxy is a deferred amplifier, so
there is no wire client here, `proxy: "require"` fails operations
closed with `station_no_proxy`, and `auto` degrades to solo with one
warning event.

```sh
make test        # vendor-links sekreto + omni, then cargo test
```

The canonical implementation is `typescript/src/*`; each module here
names the file it ports. Where the canonical library throws, this port
panics for construction-time misconfiguration (`open` conflicts, wrap
order, double binding — the generated Rust SDKs' own idiom for a broken
constructor) and returns `StationError` on the operation path (secrets,
hosts policy, `require`).

## Dependencies

`voxgig_sekreto` is the one dependency (design §10) — and Rust is the
design's stated exception to "no transitive tree": sekreto takes
`rustls` + `webpki-roots` for TLS, and that rides along. Neither
sekreto nor omni is published to crates.io yet, so `make vendor` links
sibling checkouts under `vendor/` (`SEKRETO_HOME` / `OMNI_HOME`
override the search), the same scheme sekreto's own Rust port uses for
omni. A generated SDK consumer resolves `voxgig_station` with a
`[patch.crates-io]` entry (or a path dependency) pointing at this
directory until the crate is published.

## Binding

Rust SDKs are an Rc/RefCell world: options are pure data (`Value`), no
handle can ride them, and there is no `extend` seam — so binding is the
**ambient** form only (design §3.1, tier table). Open the station, then
construct the SDK with the station feature activated in plain options;
the generated adapter (installed by `@voxgig/sdkgen-station`) binds to
the ambient instance:

```rust
use voxgig_station::{Station, StationOptions};
use taskpad_sdk::{jo, TaskpadSDK, Value};

let st = Station::open(StationOptions::default());
let pad = TaskpadSDK::new(jo(vec![(
    "feature",
    jo(vec![("station", jo(vec![("active", Value::Bool(true))]))]),
)]));

let todos = pad.todo(None).list(Value::Noval, Value::Noval)?;
st.close();
```

There is no `connect`/`adopt`: a hand-written library cannot implement
each generated SDK's own `Feature` trait (every SDK crate vendors its
own `Value`), so the retrofit path for a pre-station Rust SDK is
regeneration with the feature installed.

Because every generated SDK carries its own value types, the adapter
translates at one seam (`src/binding.rs`): `bind(BindSpec)` once at
init, `prepare()`/`done_ok()`/`done_err()` per request,
`op_start()`/`op_done()` from the hook bridge. Every binding rule —
wrap position, placeholder placement, secret-name precedence, hosts
policy, injection, events — lives in the library; the generated
adapter only converts types and deep-clones its fetchdef before
applying an injected header set (copy-on-inject, §5.3).

## Concurrency

Single-threaded by design: the generated SDKs' `Value` is neither
`Send` nor `Sync` and transports are `Rc<dyn Fn>`, so the library is
`!Send` throughout and the ambient instance is **thread-local** — each
thread that opens a Station gets its own. The §10.2 "any thread"
contract is satisfied vacuously; a multi-threaded app runs one station
per SDK-owning thread.

## Layout

| | |
|---|---|
| `src/station.rs` | the core: ambient instance, registry, events surface (ports `Station.ts`) |
| `src/binding.rs` | `bind` + per-request seam — the generated adapter's entry points (ports `adapter.ts` + the transport middleware) |
| `src/descriptor.rs` | envtoken, secretname default, descriptor normalizer, canonical serializer (ports `descriptor.ts`) |
| `src/secrets.rs` | the broker over sekreto: miss-vs-error, floorless exact-value scrub (ports `secrets.ts`) |
| `src/profile.rs` | station.json lookup + profile resolution (ports `profile.ts`) |
| `src/events.rs` | StationEvent + the bounded ring / tap (ports `events.ts`, `types.ts`) |
| `src/error.rs` | the §14 code catalog (ports `error.ts`) |
| `tests/conform.rs` | the shared `spec/station.json` corpus through voxgig/omni |
| `tests/unit.rs` | the guards and seams the corpus cannot see |
