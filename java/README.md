# station — Java

The Java port of [station](../README.md): one control surface for
outbound integrations. Solo mode only — the proxy is deferred, so there
is no wire client (design §2.1); everything runs in-process.

```sh
make test                     # the conformance suite + focused unit cases
make sync-shape               # re-mirror spec/config-shape.json
```

## Dependencies

Two, both by design and both RUNTIME:
[voxgig/sekreto](https://github.com/voxgig/sekreto) resolves secrets (the
one dependency the modem principle allowed, design §10) and
[voxgig/struct](https://github.com/voxgig/struct) validates
`station.json` against the shape (design §4, §9) — `validateConfig` runs
at `open()`, not only under test. JSON parsing borrows sekreto's own
`Json.java`. Nothing else is added.

Neither is published yet, so `make` finds them the way this port already
found voxgig/omni: `SEKRETO_HOME` / `STRUCT_HOME`, then `../../struct`,
then two fixed fallbacks. struct's own build is Maven; this port needs
one class and nothing else, so `make build` compiles
`$(STRUCT)/java/src/Struct.java` straight into `build/struct` with the
same `javac` — no network, no local repository. Only the test suite needs
voxgig/omni, and only on its classpath.

`spec/config-shape.json` is the shape artifact every port reads, and this
port carries a MIRROR of it (`src/com/voxgig/station/config-shape.json`,
copied onto the classpath at build time) because a jar ships compiled and
cannot see `spec/` at run time. `make sync-shape` rewrites the mirror;
the `shape: the mirror has not drifted` test deep-compares the two and
fails on drift — a mirror that can drift is a mirror that will.

## The declarative front door

`station.json` declares the instances; the application asks for them by
name (design §6):

```java
Station.provide("taskpad", new Factory(TaskpadSDK::new, TaskpadSDK.CONFIG));

var st = Station.open();
var pad   = st.sdk("taskpad$eu");        // constructed on first ask, then cached
var fresh = st.create("taskpad$eu");     // uncached, auto-tagged
var report = st.check();                 // stand every active instance up, in CI
var warm   = st.warm();                  // batch-resolve the fleet's secrets

var filter = new Station.FeatureFilter();
filter.feature = "debug";
var rows = st.features(filter);          // "is debug on anywhere, and with what"
```

A factory is a CONSTRUCTOR PLUS THE SDK'S STATIC CONFIG (design §6.2):
station composes the ordered feature array *for* the constructor, so it
needs the feature schemas and transport roles before construction, and
the generated package emits its config as a class-level constant that
exists as soon as the package is linked. The table is process-global,
because self-registration happens once per process and not once per
`Station`.

### `package` is not honoured here (design §6.3, and it is a divergence)

Of §6.2's three paths to a factory this port has TWO.

**Self-registration**, and in Java that is a `ServiceLoader`, not an
import: a Java `import` is a compile-time name alias that loads nothing
and runs no static initializer, so saying "importing the package
registers it" would simply be false. A generated package ships a
`META-INF/services/com.voxgig.station.Factory$Registrar` file naming an
implementation of `Factory.Registrar`, and being on the classpath is then
enough — `Factory.factoryFor` sweeps the loader once per process.

**`Station.provide(api, factory)`**, one line per api, for an
application that would rather say it out loud.

The third, THE LOADER, does not exist here and cannot: `package` names a
module in some other language's registry, and there is no
import-by-name at run time to resolve it with.

So, per design §5.4: `package` and `export` stay IN THE GRAMMAR — they
are shape keys, the corpus validates configs carrying them, and one
`station.json` serves a polyglot fleet — and this port IGNORES them at
run time, emitting one warning event per api at `open()` rather than
failing. `station_no_factory` names only the remedies Java actually
offers. `load()` is present and inert, and `load: false` is accepted and
equally inert. `station_sdk_load` stays in the §14 catalog — it is
repo-wide — and nothing this port runs raises it. What does survive from
§6.3 is `Loader.checkPackage`, the pure rule for what may appear in that
key at all (a module name, never a path or a URL, and never a `..`
segment that walks out of the named dependency); it is exported so a
Java-side tool can hold a shared `station.json` to the same rule the
loading ports apply, and it is called from nowhere in this port.

## Binding

Java is an inverted-binding target (design §3.1): the app constructs the
SDK through its existing generated constructor and hands it
station-built options — the §11 quickstart:

```java
var st = Station.open();
var solar = new SolardemoSDK(st.options());
```

The generated `station` feature (installed by
`@voxgig/sdkgen-station`) reads the handle from its feature options and
performs registration, hook bridging, and the transport wrap during
construction. `st.options(extra)` merges your own SDK options in;
`st.options(name, extra)` names the instance being built (design §6.1 —
the name is optional and leading, so every existing `options({...})` call
is unchanged). `station.plugins()`, `station.instances()`,
`station.events()`, `station.tap(fn)` and `station.status()` are the
observe surface; `station.close()` ends it.

The registry is keyed by INSTANCE (design §7.1): two clients of one api
is the normal case, two bindings of one instance is still
`station_bound_twice`, and the placeholder, the secret name, the
transport wrap and every event key on the instance while carrying its
`api` alongside.

There is no `connect(SDK)`/`adopt(SDK)` sugar here: a library-carried
adapter cannot implement a generated SDK's `Feature` interface without
depending on generated code, so the generated feature is the one binding
path and nothing rides `extend`. §3.1's retrofit path for a pre-station
Java SDK is regeneration with the feature installed. Hoist behaviour is
identical — a resident `options.apikey` handed to `st.options()` is
hoisted into the broker and replaced by the placeholder at construction.

## Maven coordinate

`com.voxgig:station` is the coordinate generated `pom.xml` files
declare (the sdkgen-station feature model's `deps.java` entry).
Publication to Maven Central is pending — until then, build with
`make build` and put `build/classes` (plus sekreto's and struct's) on the
classpath, or `mvn install:install-file` a jar of it into the local
repository.

## Layout

| | |
|---|---|
| `src/com/voxgig/station/Station.java` | open/current/reset, `options()`, the binding seam (`featureBinding`), the transport middleware, the observe surface, the §6 declarative front door |
| `src/com/voxgig/station/Shape.java` | `normalizeConfig` + `validateConfig`, over voxgig/struct (design §4.2–§4.4, §5.2) |
| `src/com/voxgig/station/config-shape.json` | the classpath mirror of `spec/config-shape.json` |
| `src/com/voxgig/station/Feature.java` | the three-level merge, the constraint-and-band order, the §8.5 checker |
| `src/com/voxgig/station/Factory.java` | the process-global factory table + the `ServiceLoader` bootstrap (design §6.2) |
| `src/com/voxgig/station/Loader.java` | `checkPackage`, and why §6.3's loader is not here |
| `src/com/voxgig/station/Descriptor.java` | `envtoken`, `secretnameDefault`, the descriptor normalizer + legacy sentinels, the canonical serializer |
| `src/com/voxgig/station/SecretBroker.java` | sekreto chain, hoisting, miss-vs-error, the floor-less exact-value scrub |
| `src/com/voxgig/station/Profile.java` | `station.json` lookup, `configScope`, profile selection and merge (wholesale `secrets.providers` replacement) |
| `src/com/voxgig/station/EventBuffer.java` | the bounded ring, tap, drop counts |
| `src/com/voxgig/station/StationError.java` | the §14 error-code catalog |
| `test/StationTest.java` | the shared conformance suite + focused unit cases |
| `test/resources/META-INF/services/` | the `Factory.Registrar` entry the self-registration test proves |

## Testing

The conformance suite runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the Java
[voxgig/omni](https://github.com/voxgig/omni) runner: `secretname`,
`placeholder`, `descriptor`, `descriptorwarnings`, `canonical`, `config`,
`instance`, `instanceref`, `feature`, and `errors`. The sections that
need live SDK machinery (inject, order, event correlation) are covered by
the focused unit cases here against the library's own seam, and
end-to-end by the generated-SDK consumer suites.

**The completeness guard.** `DRIVERS` names every corpus section this
port runs and the per-section tests are REGISTERED FROM IT, never written
out by hand; `PENDING` names the sections it deliberately does not, each
with a written reason. The `sections-covered` case reads
`spec/station.json` as raw JSON — not through the omni runner, which
would hide a section it never resolved — and asserts that DRIVERS +
PENDING exactly equals the sections the corpus carries, so a section
added upstream fails loudly here instead of silently not running, and a
driver left behind by a rename fails the other way. All ten sections run;
`PENDING` is empty.

## Where Java differs from the canonical library

Each of these is a language or dependency limit, not a decision to
disagree.

- **No loader, and no import-time self-registration.** See
  "`package` is not honoured here" above: `ServiceLoader` is the
  executable bootstrap Java has, and the loader has no meaning here at
  all.
- **No carried adapter.** A hand-written library cannot implement each
  generated SDK's own `Feature` interface, so there is no
  `connect`/`adopt` and nothing rides `extend`; the generated feature is
  the one binding path.
- **`warm()` resolves the deduplicated set serially.** The plan is
  grouped by SECRET NAME, which is where the saving is — the broker's
  resolution cache is keyed by secret name (design §5.3), so several
  instances sharing one api-level `secret` cost one round-trip. It is not
  then resolved concurrently: every public station operation is safe from
  any thread (design §10.2), so the broker is a monitor and the sekreto
  chain beneath it documents no thread safety; firing the names in
  parallel would serialize on that monitor anyway while claiming
  otherwise.
- **`$EXACT` and Java's numbers.** JSON has one number type and Java has
  six, and struct's `$EXACT` compares with `equals` — so the value handed
  to the validator is number-normalized to `double` first. A copy, and
  only the validator sees it.
- **struct's `$ONE` message spelling.** The canonical struct lowers every
  transform-command marker in an alternatives list by applying
  ``/`\$([A-Z]+)`/g`` GLOBALLY to the joined description, so a NESTED
  marker reads `[exact,library]`. struct's Java port applies that regex
  only when an alternative is itself a whole marker string, so a nested
  one comes back as ``[`$EXACT`,library]``. The config grammar is full of
  nested `$EXACT` and `$CHILD` alternatives and the corpus pins the
  canonical spelling, so `Shape` applies the same lowering to struct's
  collected messages. It rewrites nothing but a backticked `$NAME`
  marker, which is struct's own vocabulary; it goes when struct's Java
  port lands the global replace.
