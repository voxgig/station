# station — Perl

The Perl port of [station](../README.md): one control surface for
outbound integrations. Solo mode only in v1 (the proxy wire client is
deferred), per the design's tier table — perl is tier A for solo, with
remote attachment via a local forwarding proxy when that lands.

```sh
make test                     # conformance corpus + focused unit tests
```

Core modules only (`JSON::PP`, `HTTP::Tiny` transitively via sekreto,
`Time::HiRes`, `Hash::Util::FieldHash`). The one dependency is
[voxgig/sekreto](https://github.com/voxgig/sekreto)'s Perl port
(`Voxgig::Sekreto`, itself core-only): `lib/Voxgig/Station.pm` locates it
vendored beside this library, on `@INC`, via `SEKRETO_HOME`, or as a
sibling checkout.

## Use

```perl
use lib '/path/to/station/perl/lib';
use Voxgig::Station;

my $station = Voxgig::Station->open();          # profile/env defaulted
my $sdk     = $station->connect('TaskpadSDK');  # was: TaskpadSDK->new({apikey=>...})

my $todos = $sdk->Todo->list();

$station->tap(sub { print Voxgig::Station::Descriptor::canonical_serialize($_[0]), "\n" });
```

Inverted binding and the retrofit path work the same way:

```perl
my $sdk = TaskpadSDK->new($station->options());     # inverted binding
my $sdk = $station->adopt('TaskpadSDK', { apikey => $resident });  # hoists
```

## Layout

| | |
|---|---|
| `lib/Voxgig/Station.pm` | the core: ambient instance, registry, broker, transport middleware |
| `lib/Voxgig/Station/Adapter.pm` | `feature_binding` (both entry paths) + the carried adapter |
| `lib/Voxgig/Station/Descriptor.pm` | normalizer + canonical serializer + `envtoken`/`secretname_default` |
| `lib/Voxgig/Station/Error.pm` | `StationError` + the pinned code catalog |
| `lib/Voxgig/Station/Events.pm` | the bounded ring buffer + tap |
| `lib/Voxgig/Station/Profile.pm` | `station.json` lookup, profile resolution |
| `lib/Voxgig/Station/Secrets.pm` | the secret broker over `Voxgig::Sekreto` |
| `t/conform.t` | the shared conformance corpus, via voxgig/omni |
| `t/station.t` | focused unit tests (binding, injection, policy, events) |

## Vendoring

The canonical source lives HERE. The `sdkgen-station` package carries a
vendored copy (plus a vendored `Voxgig::Sekreto`) inside its perl
template overlay at `.sdk/tm/perl/feature/station/lib/`, because
generated Perl SDKs load everything by file path — the vendored
`Voxgig::Struct` precedent — and no Voxgig distribution exists on CPAN
to name in `PREREQ_PM`. Edit here first, then refresh that copy.

## Testing

`t/conform.t` runs [`spec/station.json`](../spec/station.json) — the same
file every port runs — through the Perl
[voxgig/omni](https://github.com/voxgig/omni) runner. Set `OMNI_HOME` (and
`SEKRETO_HOME`) if the checkouts are not siblings of this repository.

Perl notes, in the spirit of the omni README: scalars are untyped, so the
canonical serializer leans on `JSON::PP`'s SV-flag scalar encoding rather
than guessing numbers from strings; booleans crossing the corpus are
`JSON::PP` booleans; the transport tuple is `($response, $err)`; and a
status-0 response (how the generated transport reports network failure)
maps to the same http-0 + error events the ts library emits when its
fetch throws.
