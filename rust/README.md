# station — Rust

The Rust port of [station](../README.md): one control surface for
outbound integrations. Hand-written and modem-principle small (design
§10); solo mode only in v1 — the proxy is a deferred amplifier, so
there is no wire client here, `proxy: "require"` fails operations
closed with `station_no_proxy`, and `auto` degrades to solo with one
warning event.

```sh
make test        # vendor-links sekreto + struct + omni, then cargo test
make sync-shape  # re-copy spec/config-shape.json into the embedded mirror
```

The canonical implementation is `typescript/src/*`; each module here
names the file it ports. Where the canonical library throws, this port
panics for construction-time misconfiguration (`open` conflicts, wrap
order, double binding — the generated Rust SDKs' own idiom for a broken
constructor) and returns `StationError` on the operation path (secrets,
hosts policy, `require`).

## Dependencies

`voxgig_sekreto` and `voxgig-struct` are the two dependencies (design
§10, §9). sekreto resolves secrets; struct validates the config
grammar — and struct is a **runtime** dependency, not a test one:
`validate_config` runs at `open()`. Rust is also the design's stated
exception to "no transitive tree": sekreto takes `rustls` +
`webpki-roots` for TLS, and that rides along. Nothing else.

None of sekreto, struct or omni is published to crates.io yet, so the
Makefile links sibling checkouts under `vendor/`: `make vendor-runtime`
links the two the library needs and `make vendor` adds omni for the
suite. Each is found by `$SEKRETO_HOME` / `$STRUCT_HOME` / `$OMNI_HOME`
first, then a sibling checkout beside this one, then two fixed
fallbacks — the same convention every other port uses, and the reason
Cargo's literal path dependencies work on any machine. A generated SDK
consumer resolves `voxgig_station` with a `[patch.crates-io]` entry (or
a path dependency) pointing at this directory until the crate is
published.

### The config shape is a mirror

`spec/config-shape.json` is the config grammar, as data, and the copy
every port reads. This crate is published and compiled, so it cannot
see `spec/` at run time — and `validate_config` runs at `open()` — so
`src/config-shape.json` is an embedded **mirror** of it
(`include_str!`). `make sync-shape` rewrites the mirror;
`tests/unit.rs::config_shape_mirror_matches_the_spec` deep-compares the
two and fails on drift. Never hand-edit either file: change
`spec/config-shape.json` and re-run `make sync-shape`.

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

## The declarative front door (design §6)

`station.json` declares the instances; the application asks for one by
name and station constructs it, wraps it and registers it:

```rust
use voxgig_station::{Factory, Station, StationOptions};

// ONE LINE PER API - see "`package` is not honoured here" below.
Station::provide("taskpad", Factory {
    construct: Rc::new(|options| Rc::new(TaskpadSDK::new(to_sdk_value(options)))),
    config: taskpad_sdk::config_json(),
})?;

let st = Station::open(StationOptions::default());
let pad = st.sdk("taskpad")?;                 // constructed once, then cached
let pad = pad.downcast::<TaskpadSDK>().unwrap();
```

A factory is a **constructor plus the SDK's own embedded config**, not a
bare function: station composes the ordered feature array *for* the
constructor, so it needs the feature option schemas and transport roles
before construction, and the config is the only thing that carries them
that early. The descriptor is normalized at `provide` time, which is
what lets `check()` validate every instance's feature config with
nothing constructed.

`construct` returns `Rc<dyn Any>` and `sdk()` hands it back — a station
library cannot name a generated crate's type, so the caller downcasts.
The `Rc<dyn Any>` opacity is the same one `BindSpec.client` already
crosses the seam with.

| | |
|---|---|
| `st.sdk(name)` | construct on first ask, then CACHED by name; synchronous |
| `st.create(name, overrides)` | an UNCACHED client under an auto-assigned integer tag |
| `st.instances()` | every DECLARED instance, sorted, with `active` / `live` / `rung` |
| `st.plugins()` | every LIVE instance — exhaustive, auto-tagged entries included |
| `st.features(filter)` | the fleet feature view: instance × feature, with provenance |
| `st.features_of(name)` | one instance's merged features, order, and which level set each value |
| `st.check()` | construct every active declared instance now, and report every failure |
| `st.warm(names)` | batch-resolve secrets, deduplicated by secret name |
| `st.options_for(name, extra)` | the inverted binding, with the instance name |

`options(extra)` and `options_for(instance, extra)` are two methods
rather than one with an optional leading argument, because Rust does not
overload — the accommodation §6.3 allows a statically typed port. Every
existing `options(&extra)` call is unchanged.

`warm()` resolves **serially over the deduplicated secret-name set**
rather than concurrently: sekreto's Rust port is synchronous and this
library is `!Send` throughout, so there is no async idiom to fire them
together in (§6.9 allows this, and says to say so). The deduplication is
the half that carries the saving anyway — the broker's cache is keyed by
secret name, so several instances sharing one api-level `secret` cost
one round-trip either way.

## `package` is not honoured here (design §6.3, and it is a divergence)

Of §6.2's three paths to a factory this port has **one**:
`Station::provide`, called by the application. The other two cannot
exist in Rust.

- **Self-registration** needs a module-init hook that actually runs when
  a crate is linked. Rust has none — no `func init()`, no import side
  effect — and `#[ctor]`-style constructors are a third-party crate this
  library will not take.
- **The loader** (`api.<slug>.package`) needs import-by-name at run
  time. A Rust dependency is linked; loading one at run time means
  `dlopen` over an unstable ABI, which is a different artifact with its
  own toolchain constraints rather than the ordinary dependency graph a
  reviewer reads in `Cargo.toml`.

So `package` and `export` **stay in the grammar** — they are shape keys,
the corpus validates configs carrying them, and one `station.json`
serves a polyglot fleet — and are **ignored here, with one warning event
per api at `open()`**, never an error. `station_no_factory` names only
the remedy this port offers, and says plainly that `package` is not
honoured; `Station::load()` is present and inert, and
`StationOptions { load: Some(false) }` is accepted and equally inert.
`station_sdk_load` stays in the §14 catalog (the `errors` corpus section
pins all 29 codes for every port) and is never raised — what survives of
the loader is `check_package`, a pure predicate exported so a Rust-side
tool can hold a shared config to the same rule the loading ports apply.

## Feature declaration order

§8.4's LAST tie-break — after constraints, after bands — is the order
the config declared its features in. Station's value model IS sekreto's
`Json`, whose maps are `BTreeMap`, and omni's `Json` is a `BTreeMap`
too, so the authored order is gone before any config or corpus entry
reaches this library. `resolve_order` therefore takes the declared order
as an **explicit list** (the shape the Go port uses for the same reason)
and falls back to **bytewise key order** when it is empty, which is
every caller in this port today. Deterministic, and identical to the
authored order whenever the config is authored in sorted order. This is
the port's one behavioural divergence on §8.4, and it is the only one:
constraints, bands, the pin and the cycle check are all exact.

The same map type is why `build()` hands the constructor
`options.feature` as a **map**: the order is resolved there — so a cycle
or a pin violation fails the build — and reported by `features_of()`,
while what a Rust SDK actually inits in is its own generated feature
list, whose one station-relevant invariant (the pin) `bind()` still
verifies and fails loudly with `station_wrap_order`.

Because every generated SDK carries its own value types, the adapter
translates at one seam (`src/binding.rs`): `bind(BindSpec)` once at
init, `prepare()`/`done_ok()`/`done_err()` per request,
`op_start()`/`op_done()` from the hook bridge. `bind` returns the
instance's placeholder and the profile's `base` for the adapter to plant,
and — since Stage 5's later tranche — `Bound.allow`, the policy
allowlist in the SDK's own `options.allow` form (design §16). That last
one is ADDITIVE and the generated Rust adapter template
(`sdkgen-station/.sdk/tm/rust/feature/station.rs`, which lives outside
this port) does not apply it yet: until it does, `policy.hosts` is
enforced here at the seam as before, and `policy.allow` is computed and
handed back but not yet planted. Every binding rule —
wrap position, placeholder placement, secret-name precedence, hosts
policy, injection, events — lives in the library; the generated
adapter only converts types and deep-clones its fetchdef before
applying an injected header set (copy-on-inject, §5.3).

## Concurrency

Single-threaded by design: the generated SDKs' `Value` is neither
`Send` nor `Sync` and transports are `Rc<dyn Fn>`, so the library is
`!Send` throughout and the ambient instance is **thread-local** — each
thread that opens a Station gets its own. The §6.2 factory table is
thread-local for the same reason (everything in it is `Rc<dyn Any>`):
"process-global" means once per SDK-owning thread here, and `provide` is
called once per such thread. The §10.2 "any thread" contract is
satisfied vacuously; a multi-threaded app runs one station per
SDK-owning thread.

## Layout

| | |
|---|---|
| `src/station.rs` | the core: ambient instance, instance-keyed registry, the declarative front door, events surface (ports `Station.ts`) |
| `src/shape.rs` | `normalize_config` + `validate_config`, the embedded shape mirror, and the one seam between station's `Json` and struct's `Value` (ports `shape.ts`) |
| `src/feature.rs` | the three-level feature merge, the constraint-and-band order, the descriptor-derived §8.5 checker (ports `feature.ts`) |
| `src/factory.rs` | the process-global (per-thread) factory table and `provide` (ports `factory.ts`) |
| `src/instance.rs` | the §6.1 instance ref grammar (`instance_ref`, `check_ref`) |
| `src/loader.rs` | `check_package` and `camelify` — the pure half of `loader.ts`, and why there is no loader here |
| `src/binding.rs` | `bind` + per-request seam — the generated adapter's entry points (ports `adapter.ts` + the transport middleware) |
| `src/descriptor.rs` | envtoken, secretname default, descriptor normalizer, canonical serializer (ports `descriptor.ts`) |
| `src/secrets.rs` | the broker over sekreto: miss-vs-error, floorless exact-value scrub (ports `secrets.ts`) |
| `src/profile.rs` | station.json lookup + profile resolution (ports `profile.ts`) |
| `src/events.rs` | StationEvent + the bounded ring / tap (ports `events.ts`, `types.ts`) |
| `src/error.rs` | the §14 code catalog (ports `error.ts`) |
| `src/config-shape.json` | the embedded mirror of `spec/config-shape.json` (`make sync-shape`) |
| `corpus/tests/conform.rs` | the shared `spec/station.json` corpus through voxgig/omni |
| `tests/unit.rs` | the guards and seams the corpus cannot see |

## Corpus completeness

`corpus/tests/conform.rs` carries two named tables: `drivers()`, the
sections this port runs, and `PENDING`, the sections it deliberately does
not, each with its reason. The per-section runs are derived from
`drivers()`, so a section named there cannot silently fail to execute,
and `sections_covered` reads `spec/station.json` as raw JSON and asserts
that the two tables together cover **exactly** the sections the corpus
carries. A section added to the corpus and not picked up here fails
loudly; a stale driver or a stale pending pin fails too.

Ten sections run — `secretname`, `placeholder`, `descriptor`,
`descriptorwarnings`, `canonical`, `config`, `instance`, `instanceref`,
`feature`, `errors` — every section the corpus carries, so `PENDING` is
empty.
