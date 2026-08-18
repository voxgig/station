# station — Go

The Go port of [station](../README.md): one control surface for outbound
integrations. Hand-written and modem-principle small (design §10); solo
mode only in v1 — the proxy is a deferred amplifier, so there is no wire
client here, `proxy: "require"` fails operations closed with
`station_no_proxy`, and `auto` degrades to solo with one warning event.

```sh
make test                     # conformance + unit suites
```

The canonical implementation is `typescript/src/*`; each file here names
the file it ports. Where the canonical library throws, this port panics
for construction-time misconfiguration (`Open` conflicts, wrap order,
double binding — the generated Go SDKs' own idiom for a broken
constructor) and returns `*station.Error` on the operation path
(secrets, hosts policy, `require`).

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
| `station/station.go` | the core: ambient instance, registry, transport middleware, events surface |
| `station/binding.go` | `Bind` — the generated adapter's one entry point |
| `station/descriptor.go` | descriptor normalizer + canonical serializer (design §4) |
| `station/secrets.go` | the broker over [sekreto](https://github.com/voxgig/sekreto) (design §5) |
| `station/profile.go` | station.json lookup + profile resolution (design §3.5) |
| `station/events.go` | the bounded ring + tap (design §6) |
| `station/error.go` | the §14 catalog codes |
| `station_test.go` | the conformance suite (`spec/station.json` via voxgig/omni) |
| `unit_test.go` | the contracts the JSON corpus cannot express |

## Testing

`make test` generates a `go.work` pointing at the voxgig/omni and
voxgig/sekreto checkouts, so `go.mod` carries no path that works on only
one machine. Set `OMNI_HOME` / `SEKRETO_HOME` if they are not siblings
of this repository.

The conformance suite runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the Go omni runner. The
integration half (injection on a real wire, event correlation against a
live API) runs from a generated consumer SDK, per design §13.
