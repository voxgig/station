# station — C#

The C# port of [station](../README.md): one control surface for
outbound integrations. Solo mode only — the proxy is deferred, so there
is no wire client (design §2.1); everything runs in-process.

```sh
make test                     # the conformance suite + focused unit cases
```

The library depends on nothing but the BCL and
[voxgig/sekreto](https://github.com/voxgig/sekreto)'s C# port (the one
dependency the modem principle allows, design §10) — secrets resolve
through sekreto, JSON parsing borrows sekreto's own `Json.cs`. Only the
test suite needs voxgig/omni, and only as a project reference. Set
`SEKRETO_HOME` / `OMNI_HOME` if those checkouts are not siblings of this
repository.

## Use

C# is an inverted-binding target (design §3.1): the app constructs the
SDK through its existing generated constructor and hands it
station-built options — the §11 quickstart:

```csharp
var st = Station.Open();
var solar = new SolardemoSDK(st.Options());
```

The generated `station` feature (installed by
`@voxgig/sdkgen-station`) reads the handle from its feature options and
performs registration, hook bridging, and the transport wrap during
construction. `st.Options(extra)` merges your own SDK options in;
`st.Plugins()`, `st.Events()`, `st.Tap(fn)` and `st.Status()` are the
observe surface; `st.Close()` ends it.

There is no `Connect(SDK)`/`Adopt(SDK)` sugar here: a library-carried
adapter cannot derive from a generated SDK's `BaseFeature` without
depending on generated code, so the generated feature is the one
binding path. Its hoist behaviour is identical — a resident
`options["apikey"]` handed to `st.Options()` is hoisted into the broker
and replaced by the placeholder at construction.

## NuGet coordinate

`Voxgig.Station` is the package id generated `.csproj` files declare
(the sdkgen-station feature model's `deps.csharp` entry), and the id
this project's `<PackageId>` pins. Publication to nuget.org is pending
— and sekreto's C# port declares no `PackageId` at all yet, so it must
publish first (the library depends on it). Until then, build with
`make build` and reference `src/Station.csproj` (plus sekreto's
`Sekreto.csproj`) as project references, passing
`-p:SekretoPath=<sekreto>/csharp/src/Sekreto.csproj` when the checkout
is not a sibling.

## Layout

| | |
|---|---|
| `src/Station.cs` | Open/Current/Reset, `Options()`, the binding seam (`FeatureBinding`), the transport middleware, the observe surface |
| `src/Descriptor.cs` | `EnvToken`, `SecretnameDefault`, the descriptor normalizer + legacy sentinels, the canonical serializer |
| `src/SecretBroker.cs` | sekreto chain, hoisting, miss-vs-error, the floor-less exact-value scrub |
| `src/Profile.cs` | `station.json` lookup, profile selection and merge (wholesale `secrets.providers` replacement) |
| `src/EventBuffer.cs` | the bounded ring, tap, drop counts |
| `src/StationError.cs` | the §14 error-code catalog |
| `test/Program.cs` | the shared conformance suite + focused unit cases |

## Testing

The conformance suite runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the C#
[voxgig/omni](https://github.com/voxgig/omni) runner: `secretname`,
`placeholder`, `descriptor`, `descriptorwarnings`, `canonical`,
`instance`, and `errors`. The sections that need live SDK machinery
(inject, order, event correlation) are covered by the focused unit
cases here against the library's own seam, and end-to-end by the
generated-SDK consumer suites.

One C#-specific seam note: the generated `SdkConfig.MakeFeature`
absorbs an unknown activation name as an inert `BaseFeature` (name
`"base"`) instead of throwing, so `FeatureBinding`'s §3.3 position
guard computes the expected position from the feature list with those
inert slots skipped, not from raw adjacency — pinned by the
`binding: inert base entries` unit case.
