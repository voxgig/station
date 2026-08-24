# station — Go

The Go port of [station](../README.md): one control surface for outbound
integrations. Hand-written and modem-principle small (design §10); solo
mode only in v1 — the proxy is a deferred amplifier, so there is no wire
client here, `proxy: "require"` fails operations closed with
`station_no_proxy`, and `auto` degrades to solo with one warning event.

```sh
make test                     # conformance + unit suites
make sync-shape               # re-mirror spec/config-shape.json
```

The canonical implementation is `typescript/src/*`; each file here names
the file it ports. Where the canonical library throws, this port panics
for construction-time misconfiguration (`Open` conflicts, wrap order,
double binding — the generated Go SDKs' own idiom for a broken
constructor) and returns `*station.Error` on the operation path
(secrets, hosts policy, `require`).

## Dependencies

Two, both by design: [sekreto](https://github.com/voxgig/sekreto)
resolves secrets (design §10), and
[struct](https://github.com/voxgig/struct) validates `station.json`
against the shape (design §4, §9). Both are RUNTIME dependencies —
`ValidateConfig` runs at `Open()`, not only under test — and both are
sibling checkouts rather than published modules, so `make` finds them
(`STRUCT_HOME` / `SEKRETO_HOME`, then `../../struct`, then two fixed
fallbacks) and writes a `go.work` pointing at them. `go.mod` therefore
carries no path that works on only one machine. Nothing else is added:
the design's budget is one library plus these two.

`spec/config-shape.json` is the shape artifact every port reads, and
this port EMBEDS a mirror of it (`station/config-shape.json`, via
`go:embed`) because a Go module ships compiled and cannot see `spec/`
at run time. `make sync-shape` rewrites the mirror;
`testutil/shape_test.go` deep-compares the two and fails on drift.

## The declarative front door

`station.json` declares the instances; the application asks for them by
name (design §6):

```go
station.Provide("taskpad", station.Factory{
	Construct: func(options map[string]any) any {
		return taskpad.NewTaskpadSDK(options)
	},
	Config: taskpad.Config,
})

st, _ := station.New(nil)
client, err := st.SDK("taskpad$eu")   // constructed on first ask, then cached
fresh, err := st.Create("taskpad$eu", nil) // uncached, auto-tagged
report := st.Check()                  // stand every active instance up, in CI
warm := st.Warm(nil)                  // batch-resolve the fleet's secrets
rows, _ := st.Features(&station.FeatureFilter{Feature: "debug"})
```

A factory is a CONSTRUCTOR PLUS THE SDK'S STATIC CONFIG (design §6.2):
station composes the ordered feature array *for* the constructor, so it
needs the feature schemas before construction, and the generated
package emits its config as a package-level variable that exists as
soon as the package is linked. The table is process-global, so a
generated package can fill it from its own `func init()`.

### `package` is not honoured here (design §6.3, and it is a divergence)

Of §6.2's three paths to a factory this port has TWO:
**self-registration** — a blank import of a generated package whose
`func init()` calls `station.Provide`, which in Go actually runs — and
**`station.Provide`** called by the application, a line per api. The
third, the LOADER, does not exist here and cannot: Go links its
dependencies, so there is no import-by-name at run time.

`package` and `export` stay IN THE GRAMMAR — they are shape keys, the
corpus validates configs carrying them, and one `station.json` serves a
polyglot fleet — and this port IGNORES them at run time, emitting one
warning event per api at `Open()` rather than failing. `station_no_factory`
names only the remedies Go actually offers; a message pointing a Go user
at `api.<slug>.package` would send them down a road with no end.
`Load()` is present and inert, and `Options{Load: &no}` is accepted and
equally inert. `station_sdk_load` stays in the §14 catalog — it is
repo-wide — and is never raised here.

## Binding

Go SDKs use the inverted binding form (design §3.1) — the generated
constructor, station-built options:

```go
st := station.Open(nil)
pad := taskpad.NewTaskpadSDK(st.Options(nil))
list, err := pad.Todo(nil).List(nil, nil)
```

The generated `station` feature (installed by
`@voxgig/sdkgen-station`) reads the handle from its feature options —
or falls back to the ambient instance — and calls `station.Bind` with a
`BindSpec`: the one seam where the generated SDK's concrete types are
translated for the library. Registration, the §3.3 wrap-position guard
(via the client's feature name list — Go funcs cannot carry a marker),
placeholder placement, copy-on-inject, and the hook bridge all live in
`Bind`, never in the generated adapter.

There is no `connect`/`adopt` here: a hand-written library cannot
implement every generated SDK's own `Feature` interface, so the
retrofit path for a pre-station Go SDK is regeneration with the feature
installed.

## Layout

| | |
|---|---|
| `station/station.go` | the core: ambient instance, registry, transport middleware, events surface, the §6 declarative front door |
| `station/binding.go` | `Bind` — the generated adapter's one entry point |
| `station/descriptor.go` | descriptor normalizer + canonical serializer (design §4) |
| `station/shape.go` | `NormalizeConfig` + `ValidateConfig`, over voxgig/struct (design §4.2–§4.4, §5.2) |
| `station/config-shape.json` | the embedded mirror of `spec/config-shape.json` |
| `station/feature.go` | the three-level merge, the constraint-and-band order, the §8.5 checker |
| `station/factory.go` | the process-global factory table (design §6.2) |
| `station/instance.go` | the instance ref grammar (design §6.1) |
| `station/order.go` | JSON key-declaration order, which a Go map discards |
| `station/secrets.go` | the broker over [sekreto](https://github.com/voxgig/sekreto) (design §5) |
| `station/profile.go` | station.json lookup + profile resolution (design §3.5) |
| `station/events.go` | the bounded ring + tap (design §6) |
| `station/error.go` | the §14 catalog codes |
| `testutil/station_test.go` | the conformance suite (`spec/station.json` via voxgig/omni) |
| `testutil/shape_test.go` | the shape mirror's drift guard, and the shape's own invariants |
| `unit_test.go` | the contracts the JSON corpus cannot express: binding, events, the scrub |
| `declarative_test.go` | the same, for the factory table and the §6 front door |

## Testing

`make test` generates a `go.work` pointing at the voxgig/omni,
voxgig/sekreto and voxgig/struct checkouts, so `go.mod` carries no path
that works on only one machine. Set `OMNI_HOME` / `SEKRETO_HOME` /
`STRUCT_HOME` if they are not siblings of this repository.

`make build-clean` is the register-4.13 proof: the published module
must build, and its own tests must run, with NO omni checkout present.
The conformance suite is a nested module (`testutil`) precisely so that
`go mod tidy` cannot quietly add omni to the published dependency
graph; sekreto and struct stay requires of this module because the
LIBRARY depends on them.

The conformance suite runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the Go omni runner. The
integration half (injection on a real wire, event correlation against a
live API) runs from a generated consumer SDK, per design §13.

**The completeness guard.** `DRIVERS` names every corpus section this
port runs and the per-section tests are REGISTERED FROM IT, never
written out by hand; `PENDING` names the sections it deliberately does
not, each with a written reason. `TestSectionsCovered` reads
`spec/station.json` as raw JSON and asserts that DRIVERS + PENDING
exactly equals the sections the corpus carries — so a section added
upstream fails loudly here instead of silently not running, and a
driver left behind by a rename fails the other way. Ten sections run;
`profile` alone is pending, because it pins the pre-rename `plugin`
grammar the `instance` section supersedes.

## Where Go differs from the canonical library

Each of these is a language limit, not a decision to disagree.

- **Errors vs panics.** The canonical library throws; this port panics
  for construction-time misconfiguration (`Open` conflicts, wrap order,
  a second binding of one instance, a factory conflict — the generated
  Go SDKs' own idiom for a broken constructor) and returns
  `*station.Error` everywhere else, the declarative front door
  included.
- **`Options(extra)` / `OptionsFor(name, extra)`.** Go cannot overload
  on a leading optional argument, so the canonical
  `options(instanceName?, extra?)` is two methods and every existing
  `Options({...})` call is unchanged.
- **`Features(filter)`.** The object form is `*FeatureFilter`; the
  string shorthand — "this instance or this api" — is
  `station.LooseFilter(text)`.
- **Declaration order.** §8.4's LAST tie-break, after constraints and
  bands, is the order the config declared its features in. A Go map has
  none, so `station.json` is parsed by an order-preserving reader
  (`station/order.go`) and the order is threaded to `ResolveOrder`
  explicitly. A config passed in code (`Options.Config`) has no order to
  read — a Go map literal simply has none — so those instances fall back
  to sorted names.
- **The composed order cannot ride the options map.** `Build` resolves
  the full §8.4 order (so a cycle or a pin violation fails the build)
  and `FeaturesOf` reports it, but the generated Go constructor takes
  `options["feature"]` as a map, which carries no order; what a Go SDK
  inits in is its own generated feature list. The one station-relevant
  invariant of that list — station's pin, immediately outside the base
  transport — is still verified at `Bind`, which fails
  `station_wrap_order`.
- **No carried adapter.** A hand-written library cannot implement each
  generated SDK's own `Feature` interface, so §3.1's retrofit path for a
  pre-station Go SDK is regeneration with the feature installed; there
  is no `connect`/`adopt` and nothing rides `extend`.
- **`$EXACT` and Go's numbers.** JSON has one number type and Go has
  fifteen, and struct's `$EXACT` compares with `reflect.DeepEqual` — so
  the value handed to the validator is number-normalized to the kind
  `encoding/json` produces first. A copy, and only the validator sees
  it.
