# station — Perl

The Perl port of [station](../README.md): one control surface for
outbound integrations. Solo mode only in v1 (the proxy wire client is
deferred), per the design's tier table — perl is tier A for solo, with
remote attachment via a local forwarding proxy when that lands.

```sh
make test                     # conformance corpus + focused unit tests
```

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

## The declarative front door

`station.json` names the instances, and `sdk($name)` is how you get one —
constructed on first ask and CACHED, so "get it where you need it" is a
real instruction:

```perl
my $station = Voxgig::Station->open();
my $pad = $station->sdk('taskpad');        # cached: same name, same client
my $eu  = $station->sdk('taskpad$eu');     # a second instance of one api
my $one = $station->create('taskpad');     # UNCACHED, auto-tagged taskpad$1
```

An instance ref is `<name>$<tag>`, and `as` is a TAG rather than a free
name (design station.md 6.1): `connect($SDK, { as => 'test' })` on api
`taskpad` is the instance `taskpad$test`, and a `$`-less `as` is always a
tag — `as => 'taskpad'` gives `taskpad$taskpad`, never the untagged
instance. Someone who wants that passes no `as` at all.

Station has to know how to construct an api before it constructs one, so
a **factory is a constructor PLUS the SDK's static config** (6.2) — the
feature option schemas and transport roles have to be readable BEFORE
construction, and the adapter only registers its descriptor DURING it.
Three paths fill the process-global table, in order of preference:

1. **Self-registration.** A generated package calls
   `Voxgig::Station::Factory::provide` when it is loaded, so putting it
   on `@INC` is enough.
2. **`Voxgig::Station->provide($api, $factory)`** — one line per api:

   ```perl
   Voxgig::Station->provide('taskpad', {
       construct => sub { return TaskpadSDK->new( $_[0] ) },
       config    => $TaskpadSDK::CONFIG,
   });
   ```
3. **The loader.** `api.<slug>.package` names a module for station to
   `require`. Perl resolves modules by name at runtime, so this port has
   a loader — see the note below for what that does and does not reach.

The rest of the surface: `instances()` lists every DECLARED instance
(live or not), `plugins()` lists every LIVE one, `features($filter)` is
the fleet feature view with per-value provenance, `check()` turns
deferred availability errors into one CI failure, and `warm($names)`
batch-resolves credentials.

## Resolution

Core modules only (`JSON::PP`, `HTTP::Tiny` transitively via sekreto,
`Time::HiRes`, `Hash::Util::FieldHash`) plus the two Voxgig
dependencies the modem principle allows (design station.md 10, 9):

- **[voxgig/sekreto](https://github.com/voxgig/sekreto)**
  (`Voxgig::Sekreto`) resolves secrets. `lib/Voxgig/Station.pm` locates
  it vendored beside this library, on `@INC`, via `SEKRETO_HOME`, or as
  a sibling checkout.
- **[voxgig/struct](https://github.com/voxgig/struct)**
  (`Voxgig::Struct`) backs `validate_config`, and it is a **runtime**
  dependency: the validator runs at `open()`, not only under test.
  `lib/Voxgig/Station/Struct.pm` finds it the same way — already
  loadable first, then `$STRUCT_HOME`, then a sibling checkout beside
  the station checkout, then two fixed fallbacks. Resolution is LAZY, so
  `use Voxgig::Station` does not fail for a caller that never validates
  a config.

The config grammar itself is DATA: this port reads
[`spec/config-shape.json`](../spec/config-shape.json) at runtime, like
the javascript, python and ruby ports, because it runs straight from
`lib` in the checkout. The lookup walks up from the library root, so a
vendored copy finds `feature/station/spec/config-shape.json` — see
Vendoring.

## Layout

| | |
|---|---|
| `lib/Voxgig/Station.pm` | the core: ambient instance, ref grammar, instance-keyed registry, broker, transport middleware, the declarative front door |
| `lib/Voxgig/Station/Adapter.pm` | `feature_binding` (both entry paths) + the carried adapter |
| `lib/Voxgig/Station/Descriptor.pm` | normalizer + canonical serializer + `envtoken`/`secretname_default` |
| `lib/Voxgig/Station/Shape.pm` | `normalize_config`, `validate_config`, the defaults tables |
| `lib/Voxgig/Station/Feature.pm` | the feature merge, the order resolver, the descriptor-derived checker |
| `lib/Voxgig/Station/Factory.pm` | the process-global factory table and `provide` |
| `lib/Voxgig/Station/Loader.pm` | `package` checking and the require-by-name loader |
| `lib/Voxgig/Station/Struct.pm` | voxgig/struct discovery, and the ordered map 8.4 needs |
| `lib/Voxgig/Station/Error.pm` | `StationError` + the pinned code catalog |
| `lib/Voxgig/Station/Events.pm` | the bounded ring buffer + tap |
| `lib/Voxgig/Station/Profile.pm` | `station.json` lookup, config scope, profile resolution |
| `lib/Voxgig/Station/Secrets.pm` | the secret broker over `Voxgig::Sekreto` |
| `t/conform.t` | the shared conformance corpus, via voxgig/omni |
| `t/station.t` | focused unit tests (binding, injection, policy, events, the declarative surface) |
| `t/lib/StationTest*.pm` | loader fixtures: a package that self-registers, and one the retrofit path reads |

## Vendoring

The canonical source lives HERE. The `sdkgen-station` package carries a
vendored copy (plus a vendored `Voxgig::Sekreto`) inside its perl
template overlay at `.sdk/tm/perl/feature/station/lib/`, because
generated Perl SDKs load everything by file path — the vendored
`Voxgig::Struct` precedent — and no Voxgig distribution exists on CPAN
to name in `PREREQ_PM`. Edit here first, then refresh that copy.

Two things ride along with that refresh now: a vendored
`Voxgig::Struct`, because `validate_config` needs it at `open()`, and
`spec/config-shape.json` copied to `feature/station/spec/`, because the
shape is data the library reads rather than code it carries.

## Testing

`t/conform.t` runs [`spec/station.json`](../spec/station.json) — the same
file every port runs — through the Perl
[voxgig/omni](https://github.com/voxgig/omni) runner. Set `OMNI_HOME`
(and `SEKRETO_HOME`, `STRUCT_HOME`) if the checkouts are not siblings of
this repository.

The suite runs every one of the corpus's ten sections, and WHICH ones is
not a matter of what happens to be written out by hand: `t/conform.t`
declares a `@DRIVERS` table (section name -> subject) and a `@PENDING`
table (section name -> the reason it is not run), REGISTERS the
per-section tests from `@DRIVERS`, and the `sections-covered` guard
asserts that drivers plus pending EXACTLY equals the sections
`spec/station.json` carries — read as raw JSON, not through the runner,
so a section the runner never resolved cannot hide. A section added to
the corpus and not picked up here fails loudly instead of silently not
running, and a section dropped from `@DRIVERS` to make a red test go away
must be moved to `@PENDING` with a written reason.

`@PENDING` is currently EMPTY — nothing is pinned — so that guard reduces
to drivers EXACTLY equals the corpus's sections.

## Perl notes

In the spirit of the omni README, the places where the language decides
something rather than the design:

- **Scalars are untyped**, so the canonical serializer leans on
  `JSON::PP`'s SV-flag scalar encoding rather than guessing numbers from
  strings, and both `kindof` spellings (the shape one and the feature
  one) make the same test. Booleans crossing the corpus or a
  serialization boundary are `JSON::PP` booleans; the tree handed to
  struct's validator is converted to struct's own booleans on the way
  in, because `typify` knows only its own.
- **The transport tuple is `($response, $err)`**, and a status-0
  response (how the generated transport reports network failure) maps to
  the same http-0 + error events the ts library emits when its fetch
  throws.
- **A perl hash has no key order**, and design 8.4 makes declaration
  order load-bearing — it is the LAST tie-break of the feature order. So
  `station.json` is read through struct's own order-preserving JSON
  reader rather than `JSON::PP`'s, every feature map station builds is
  an insertion-ordered map, and `mapkeys` answers insertion order where
  there is one and sorted keys where there is none.
  **The divergence:** a config passed IN CODE (`Voxgig::Station->new({
  config => {...} })`) is a plain perl hash and has no order to read, so
  for those instances the tie-break falls back to sorted keys.
  Constraints and bands are unaffected; only a tie no constraint and no
  band decides is.
- **One module system, so one loader.** ts/js need
  `await station->load()` because an ESM-only package cannot be required
  from a synchronous `sdk()`; perl has no such split, so `load()` is a
  SYNCHRONOUS preload of the declared packages and nothing needs it
  before `sdk()`. It is kept because loading the fleet at startup — where
  an import error is one failure at a moment somebody is watching — is
  worth having.
- **The "module" a retrofit factory is read off is a PACKAGE NAME**,
  because `require` returns a truth value rather than a module object.
  `export` names a class in it, tried as written, then under the
  package; `config` is looked for as a sub first and then as a `config`
  or `CONFIG` package variable, on the package and then on the
  constructor class — which in perl is itself a package. The name is
  turned into a path for `require` (`A::B` -> `A/B.pm`) rather than
  passed through a string eval, so nothing from a config file is ever
  compiled as perl source.
  **The standing limit** is the perl target's rather than the loader's:
  a generated Perl SDK is a FILE TREE loaded by absolute path, not a
  CPAN distribution, so `api.<slug>.package` resolves only when the
  application has put that tree on `@INC` (`use lib`). Where it has not,
  paths 1 and 2 — self-registration and `Voxgig::Station->provide` — are
  the ones that work.
- **`warm` deduplicates but does not parallelize.** It resolves one
  credential per DISTINCT SECRET NAME, which is the half that matters —
  the broker's resolution cache is keyed by secret name, so several
  instances sharing one api-level `secret` cost one round-trip. This
  port has no async idiom, so those distinct names resolve SERIALLY
  rather than concurrently.
- **`options` takes an optional LEADING instance name**
  (`$station->options($name, $extra)`), so every existing
  `$station->options({...})` call is unchanged.
- **Construction options are snake_case** here, matching the rest of the
  port: `repo_scoped`, not `repoScoped`.
