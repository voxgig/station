# station — Java

The Java port of [station](../README.md): one control surface for
outbound integrations. Solo mode only — the proxy is deferred, so there
is no wire client (design §2.1); everything runs in-process.

```sh
make test                     # the conformance suite + focused unit cases
```

The library depends on nothing but the JDK and
[voxgig/sekreto](https://github.com/voxgig/sekreto)'s Java port (the one
dependency the modem principle allows, design §10) — secrets resolve
through sekreto, JSON parsing borrows sekreto's own `Json.java`. Only
the test suite needs voxgig/omni, and only on its classpath. Set
`SEKRETO_HOME` / `OMNI_HOME` if those checkouts are not siblings of this
repository.

## Use

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
`station.plugins()`, `station.events()`, `station.tap(fn)` and
`station.status()` are the observe surface; `station.close()` ends it.

There is no `connect(SDK)`/`adopt(SDK)` sugar here: a library-carried
adapter cannot implement a generated SDK's `Feature` interface without
depending on generated code, so the generated feature is the one
binding path. Its hoist behaviour is identical — a resident
`options.apikey` handed to `st.options()` is hoisted into the broker
and replaced by the placeholder at construction.

## Maven coordinate

`com.voxgig:station` is the coordinate generated `pom.xml` files
declare (the sdkgen-station feature model's `deps.java` entry).
Publication to Maven Central is pending — until then, build with
`make build` and put `build/classes` (plus sekreto's) on the classpath,
or `mvn install:install-file` a jar of it into the local repository.

## Layout

| | |
|---|---|
| `src/com/voxgig/station/Station.java` | open/current/reset, `options()`, the binding seam (`featureBinding`), the transport middleware, the observe surface |
| `src/com/voxgig/station/Descriptor.java` | `envtoken`, `secretnameDefault`, the descriptor normalizer + legacy sentinels, the canonical serializer |
| `src/com/voxgig/station/SecretBroker.java` | sekreto chain, hoisting, miss-vs-error, the floor-less exact-value scrub |
| `src/com/voxgig/station/Profile.java` | `station.json` lookup, profile selection and merge (wholesale `secrets.providers` replacement) |
| `src/com/voxgig/station/EventBuffer.java` | the bounded ring, tap, drop counts |
| `src/com/voxgig/station/StationError.java` | the §14 error-code catalog |
| `test/StationTest.java` | the shared conformance suite + focused unit cases |

## Testing

The conformance suite runs [`spec/station.json`](../spec/station.json)
— the same file every port runs — through the Java
[voxgig/omni](https://github.com/voxgig/omni) runner: `secretname`,
`placeholder`, `descriptor`, `descriptorwarnings`, `canonical`,
`profile`, and `errors`. The sections that need live SDK machinery
(inject, order, event correlation) are covered by the focused unit
cases here against the library's own seam, and end-to-end by the
generated-SDK consumer suites.
