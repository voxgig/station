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

The secret comes from sekreto's default `env` chain: for a plugin whose
slug is `taskpad`, the name `taskpad.apikey` resolves from the
`TASKPAD_APIKEY` environment variable - exactly the variable the
generated SDK's README already documents. `options_map`/`prepare` output
carries only the `[station:taskpad]` placeholder; the middleware swaps
in the real value at send time (design station.md 5).

## Resolution

Neither `voxgig_station` nor `voxgig_sekreto` is published as a gem yet;
the require path is the resolution story:

```sh
ruby -I /path/to/station/ruby/lib -I /path/to/sekreto/ruby/lib app.rb
```

## Layout

| File | Contents |
|---|---|
| `lib/voxgig_station/station.rb` | Station core: registry, transport middleware, events, close |
| `lib/voxgig_station/adapter.rb` | feature_binding + the carried adapter (adopt/connect retrofit) |
| `lib/voxgig_station/descriptor.rb` | envtoken, secretname default, normalizer, canonical serializer |
| `lib/voxgig_station/secrets.rb` | placeholder + SecretBroker over voxgig_sekreto |
| `lib/voxgig_station/profile.rb` | station.json lookup, profile resolution |
| `lib/voxgig_station/events.rb` | bounded ring buffer + tap |
| `lib/voxgig_station/error.rb` | the error-code catalog (design station.md 14) |
| `test/conform_test.rb` | the shared spec/station.json corpus, via voxgig/omni |
| `test/station_test.rb` | binding/middleware/event unit tests over a miniature SDK |

## Notes

- Standard library only, plus `voxgig_sekreto` (the one dependency the
  modem principle allows - design station.md 10).
- SDK-facing seams follow the generated Ruby SDKs: the transport is a
  lambda returning a `[response, err]` tuple, and a network-level
  failure is a synthesized status-0 response - the middleware maps it to
  the same status-0 http event plus error event the ts library emits
  when its transport throws.
- Data is string-keyed (the generated SDKs' convention); construction
  options accept string or symbol keys.
