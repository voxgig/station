# station - Ruby

Ruby port of the canonical TypeScript implementation. Solo mode only in
v1 (the proxy client is deferred with the proxy itself).

```sh
make test
```

## Use

```ruby
require 'voxgig_station'

station = VoxgigStation::Station.open        # profile/env all defaulted
pad = station.connect(TaskpadSDK)            # was: TaskpadSDK.new({ "apikey" => ... })

pad.Todo.list
station.events                               # correlated op + http events
```

Inverted binding uses the constructor the SDK already generates:

```ruby
pad = TaskpadSDK.new(station.options)
```

The secret comes from sekreto's default `env` chain: for an instance
named `taskpad`, the name `taskpad.apikey` resolves from the
`TASKPAD_APIKEY` environment variable - exactly the variable the
generated SDK's README already documents. `options_map`/`prepare` output
carries only the `[station:taskpad]` placeholder; the middleware swaps
in the real value at send time (design station.md 5).

## The declarative front door

`station.json` names the instances, and `sdk(name)` is how you get one -
constructed on first ask and cached, so "get it where you need it" is a
real instruction:

```ruby
station = VoxgigStation::Station.open
pad = station.sdk('taskpad')                 # cached: same name, same client
eu  = station.sdk('taskpad$eu')              # a second instance of one api
one = station.create('taskpad')              # UNCACHED, auto-tagged taskpad$1
```

An instance ref is `<name>$<tag>`, and `as:` is a TAG rather than a free
name (design station.md 6.1): `connect(SDK, 'as' => 'test')` on api
`taskpad` is the instance `taskpad$test`.

Station needs to know how to construct an api before it constructs one,
so a **factory** is a constructor PLUS the SDK's static config (6.2).
Three paths fill the process-global table, in order of preference:

1. **Self-registration.** A generated package calls
   `VoxgigStation.provide` at `require` time, so linking it is enough.
2. **`VoxgigStation::Station.provide(api, factory)`** - one line per api:

   ```ruby
   VoxgigStation::Station.provide('taskpad',
     'construct' => ->(o) { TaskpadSDK.new(o) }, 'config' => Taskpad::CONFIG)
   ```
3. **The loader.** `api.<slug>.package` names a module for station to
   `require`. Ruby resolves modules by name at runtime, so this port has
   a loader; the value must be a bare module name (never a path, a URL
   or anything with a `..` segment), and it is honoured only from
   repo-scoped config - a `package` arriving from
   `~/.voxgig/station.json` is ignored with a warning event, because it
   names code to load and sits outside the repo's review boundary (6.3).

The rest of the surface: `instances()` lists every declared instance
(live or not), `plugins()` lists every live one, `features(filter)` is
the fleet feature view with per-value provenance, `check()` turns
deferred availability errors into one CI failure, and `warm(names)`
batch-resolves credentials.

## Resolution

Neither `voxgig_station` nor `voxgig_sekreto` is published as a gem yet;
the require path is the resolution story:

```sh
ruby -I /path/to/station/ruby/lib -I /path/to/sekreto/ruby/lib app.rb
```

`voxgig_struct` backs `validate_config` and is a RUNTIME dependency - it
runs at `open()`, not only under test. It is found the way the suites
find omni: `$STRUCT_HOME`, then a sibling checkout beside the station
checkout, then two fixed fallbacks (`lib/voxgig_station/structhome.rb`).
An installed gem wins over the checkout when there is one.

The config grammar itself is DATA: this port reads
`spec/config-shape.json` from the repo at runtime, like the javascript
and python ports, because it runs straight from `lib` in the checkout. A
port that ships a compiled or published artifact which cannot see
`spec/` needs an embedded mirror plus a drift guard instead; if this port
ever ships a gem, that is the change to make.

## Layout

| File | Contents |
|---|---|
| `lib/voxgig_station/station.rb` | Station core: registry, transport middleware, the declarative front door, events, close |
| `lib/voxgig_station/adapter.rb` | feature_binding + the carried adapter (adopt/connect retrofit) |
| `lib/voxgig_station/descriptor.rb` | envtoken, secretname default, normalizer, canonical serializer |
| `lib/voxgig_station/shape.rb` | normalize_config, validate_config, the defaults tables |
| `lib/voxgig_station/feature.rb` | the feature merge, the order resolver, the descriptor-derived checker |
| `lib/voxgig_station/factory.rb` | the process-global factory table and `provide` |
| `lib/voxgig_station/loader.rb` | `package` checking and the require-by-name loader |
| `lib/voxgig_station/structhome.rb` | sibling voxgig/struct discovery |
| `lib/voxgig_station/secrets.rb` | placeholder + SecretBroker over voxgig_sekreto |
| `lib/voxgig_station/profile.rb` | station.json lookup, config scope, profile resolution |
| `lib/voxgig_station/events.rb` | bounded ring buffer + tap |
| `lib/voxgig_station/error.rb` | the error-code catalog (design station.md 14) |
| `test/conform_test.rb` | the shared spec/station.json corpus, via voxgig/omni |
| `test/station_test.rb` | binding/middleware/event and declarative-surface unit tests |

## Conformance

The suite runs all ten of the corpus's sections. Which ones is not a
matter of what happens to be written out by hand: `test/conform_test.rb`
declares a `DRIVERS` table (section name -> subject) and a `PENDING`
table (section name -> the reason it is not run, currently empty),
REGISTERS the per-section tests from `DRIVERS`, and the
`sections_covered` guard asserts that `DRIVERS` plus `PENDING` exactly
equals the sections `spec/station.json` carries - read as raw JSON, not
through the runner, so a section the runner never resolved cannot hide.
A section added to the corpus and not picked up here fails loudly
instead of silently not running, and a section dropped from `DRIVERS` to
make a red test go away must be moved to `PENDING` with a written
reason.

## Notes

- Standard library only, plus `voxgig_sekreto` and `voxgig_struct` - the
  two dependencies the modem principle allows (design station.md 10, 9).
- SDK-facing seams follow the generated Ruby SDKs: the transport is a
  lambda returning a `[response, err]` tuple, and a network-level
  failure is a synthesized status-0 response - the middleware maps it to
  the same status-0 http event plus error event the ts library emits
  when its transport throws.
- Data is string-keyed (the generated SDKs' convention); construction
  options accept string or symbol keys, and `repo_scoped` is also
  accepted as `repoScoped`.
- **One module system, so one loader.** ts/js need
  `await station.load()` because an ESM-only package cannot be required
  from a synchronous `sdk()`; Ruby has no such split, so there is no
  async loader and `Station#load` is a SYNCHRONOUS preload of the
  declared packages that nothing needs before `sdk()`. It is kept
  because loading the fleet at startup - where a require error is one
  failure at a moment somebody is watching - is worth having.
- `require` returns true, not a module object, so the "module" a
  retrofit factory is read off is a NAMESPACE (`Object` for a package
  whose generated class is top-level) and `export` names a CONSTANT in
  it. `config` is looked for as a method first and then as a `CONFIG`
  constant, on the namespace and then on the constructor class - which
  in Ruby is itself a namespace.
- `warm` resolves one credential per DISTINCT SECRET NAME and resolves
  them together, on threads: the broker's resolution cache is keyed by
  secret name, so several instances sharing one api-level `secret` cost
  one round-trip, and awaiting inside the loop would make `warm` cost the
  sum of every provider round-trip.
