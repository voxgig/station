// RUN: make test
// RUN-SOME: java -cp ... StationTest secretname
//
// The station conformance suite: the pure-contract half of the design's
// (13) corpus, from spec/station.json, through voxgig/omni - the same file
// every port runs. Sections that need live SDK machinery (inject, order,
// event correlation) live in the consumer end-to-end suites against real
// generated SDKs; the corpus carries what a port can prove with no SDK
// present. The focused unit cases below cover the station mechanics the
// corpus cannot reach without an SDK: the event ring, the broker's
// miss-vs-error and floor-less scrub, the binding guards, the transport
// middleware's copy-on-inject, the shape mirror, the factory table and the
// design 6 declarative front door.
//
// No third-party test framework: a failing omni check throws OmniError, so
// `make test` stays dependency-free (the sekreto/omni pattern).

import com.voxgig.omni.Runner;
import com.voxgig.omni.Runner.OmniError;
import com.voxgig.omni.Runner.RunPack;
import com.voxgig.omni.Runner.Subject;

import com.voxgig.sekreto.Json;
import com.voxgig.sekreto.Sekreto;

import com.voxgig.station.Descriptor;
import com.voxgig.station.EventBuffer;
import com.voxgig.station.Factory;
import com.voxgig.station.Feature;
import com.voxgig.station.Loader;
import com.voxgig.station.Profile;
import com.voxgig.station.SecretBroker;
import com.voxgig.station.Shape;
import com.voxgig.station.Station;
import com.voxgig.station.StationError;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

@SuppressWarnings({"unchecked"})
public final class StationTest {

  private static String only = null;
  private static int passcount = 0;
  private static int failcount = 0;

  private StationTest() {}

  /** Find the shared spec directory by walking up from the class path. */
  static String specfile(String name) {
    File dir = new File(System.getProperty("user.dir"));

    for (int step = 0; step < 8 && null != dir; step++) {
      File cand = new File(new File(dir, "spec"), name);
      if (cand.exists()) {
        return cand.getAbsolutePath();
      }
      dir = dir.getParentFile();
    }

    throw new OmniError("station: spec not found: " + name);
  }

  static Object parsefile(String path) {
    try {
      return Json.parse(new String(
          Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8));
    } catch (Exception err) {
      throw new OmniError("station: cannot read " + path + ": " + err);
    }
  }

  // --- corpus subjects ---

  static final Subject SECRETNAME = args -> {
    String slug = String.valueOf(((Map<?, ?>) args[0]).get("slug"));
    String secretname = Descriptor.secretnameDefault(slug);
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("envtoken", Descriptor.envtoken(slug));
    out.put("secretname", secretname);
    out.put("envkey", Sekreto.envkey(secretname, null));
    return out;
  };

  static final Subject PLACEHOLDER = args ->
      SecretBroker.placeholderFor(String.valueOf(args[0]));

  static final Subject DESCRIPTOR = args -> {
    Map<?, ?> vin = (Map<?, ?>) args[0];
    return Descriptor.normalizeDescriptor(vin.get("config"), vin.get("feature")).descriptor;
  };

  static final Subject DESCWARN = args -> {
    Map<?, ?> vin = (Map<?, ?>) args[0];
    return Descriptor.normalizeDescriptor(vin.get("config"), vin.get("feature"))
        .warnings.size();
  };

  // Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
  // subject sees what the spec means.
  static Object denull(Object val) {
    if (Runner.NULLMARK.equals(val)) {
      return null;
    }
    if (val instanceof List) {
      List<Object> out = new ArrayList<>();
      for (Object entry : (List<Object>) val) {
        out.add(denull(entry));
      }
      return out;
    }
    if (val instanceof Map) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : ((Map<String, Object>) val).entrySet()) {
        out.put(entry.getKey(), denull(entry.getValue()));
      }
      return out;
    }
    return val;
  }

  static Map<String, Object> denullmap(Object val) {
    Object out = denull(val);
    return out instanceof Map ? (Map<String, Object>) out : null;
  }

  static final Subject CANONICAL = args ->
      Descriptor.canonicalSerialize(denull(args[0]));

  // Normalize, then validate (design 4.2). The entry is a RAW config in,
  // and either the normalized output or the expected error out - the two
  // steps are ONE pipeline, and a port that splits them is free to
  // validate the wrong form.
  static final Subject CONFIG = args ->
      Shape.validateConfig(Shape.normalizeConfig(denull(args[0])));

  static final Subject INSTANCE = args -> {
    Map<?, ?> vin = (Map<?, ?>) args[0];
    return Profile.resolveProfile(vin.get("config"), String.valueOf(vin.get("profile")));
  };

  // Design 6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
  // rather than driver-shaped even though it decides a registry key.
  static final Subject INSTANCEREF = args -> {
    Map<?, ?> vin = (Map<?, ?>) args[0];
    return Station.instanceRef(
        String.valueOf(vin.get("api")), denullmap(vin.get("opts")));
  };

  // Design 8's pure half: the three-level merge with its depth boundary,
  // and the design 8.4 order resolution. ONE driver, TWO entry shapes -
  // `merged` selects the resolver, anything else the merge - because a
  // port that guessed from looser cues would run the wrong subject on a
  // mistyped entry.
  static final Subject FEATURE = args -> {
    Map<String, Object> vin = (Map<String, Object>) args[0];
    if (vin.containsKey("merged") && !Runner.NULLMARK.equals(vin.get("merged"))) {
      List<Feature.Ordered> ordered =
          Feature.resolveorder(denullmap(vin.get("merged")));
      Feature.checkpin(ordered);
      return Feature.featureNames(ordered);
    }
    return Feature.mergefeatures(Feature.featuresources(
        denullmap(vin.get("base")), denullmap(vin.get("overlay")),
        text(vin.get("api")), text(vin.get("ref"))));
  };

  static final Subject ERRORS = args -> StationError.isKnownCode(args[0]);

  // --- the opt-in surface, and the completeness guard ---

  static final class Driver {
    final String name;
    final Subject subject;

    Driver(String name, Subject subject) {
      this.name = name;
      this.subject = subject;
    }
  }

  // DRIVERS is the opt-in surface: one driver per corpus section this port
  // RUNS, and the per-section tests below are REGISTERED FROM THIS TABLE,
  // never written out by hand. A section listed here cannot silently fail
  // to execute, and `sections-covered` closes the other direction.
  static final List<Driver> DRIVERS = List.of(
      new Driver("secretname", SECRETNAME),
      new Driver("placeholder", PLACEHOLDER),
      new Driver("descriptor", DESCRIPTOR),
      new Driver("descriptorwarnings", DESCWARN),
      new Driver("canonical", CANONICAL),
      new Driver("config", CONFIG),
      new Driver("instance", INSTANCE),
      new Driver("instanceref", INSTANCEREF),
      new Driver("feature", FEATURE),
      new Driver("errors", ERRORS));

  // PENDING is the sections this port deliberately does NOT run, with the
  // reason - an entry here is a RECORDED DECISION, not an omission.
  static final List<String[]> PENDING = List.<String[]>of(
      // Pins the pre-Stage-1 `plugin` grammar, which this port no longer
      // speaks. It stays in the corpus for the ports that have not crossed
      // the rename yet and is deleted when the last one does - see
      // spec/README.md. Everything it pins is restated in the sdk/api
      // grammar the `instance` section runs.
      new String[] {
        "profile", "pre-rename plugin grammar; superseded by the instance section" });

  // --- harness ---

  interface Body {
    void run() throws Exception;
  }

  static void testcase(String name, Body body) {
    if (null != only && !name.equals(only)) {
      return;
    }

    try {
      body.run();
      passcount++;
      System.out.println("ok   - " + name);
    } catch (Throwable err) {
      failcount++;
      System.out.println("FAIL - " + name);
      System.out.println(err.getMessage());
    }
  }

  static void check(boolean cond, String what) {
    if (!cond) {
      throw new IllegalStateException("station: check failed: " + what);
    }
  }

  static void checkeq(Object got, Object want, String what) {
    if (!String.valueOf(got).equals(String.valueOf(want))) {
      throw new IllegalStateException("station: check failed: " + what
          + "\n  got:  " + got + "\n  want: " + want);
    }
  }

  static String text(Object val) {
    return val instanceof String ? (String) val : null;
  }

  static Map<String, Object> map(Object... pairs) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int index = 0; index + 1 < pairs.length; index += 2) {
      out.put(String.valueOf(pairs[index]), pairs[index + 1]);
    }
    return out;
  }

  // A station over a memory provider chain, isolated from the ambient
  // instance and from any station.json on disk.
  static Station memoryStation(Map<String, Object> values, Map<String, Object> plugin) {
    return memoryStation(values, plugin, null);
  }

  static Station memoryStation(Map<String, Object> values,
      Map<String, Object> sdk, Map<String, Object> api) {
    Map<String, Object> profile = map(
        "secrets", map("providers", List.of(map("kind", "memory", "values", values))));
    if (null != sdk) {
      profile.put("sdk", sdk);
    }
    if (null != api) {
      profile.put("api", api);
    }
    Map<String, Object> config = map(
        "station", 1, "profiles", map("default", profile));
    return new Station(map("config", config));
  }

  // The embedded-config shape a generated SDK carries, small.
  static Map<String, Object> sdkconfig(String name, String slug) {
    Map<String, Object> main = map("name", name);
    if (null != slug) {
      main.put("slug", slug);
      main.put("version", "0.0.1");
      main.put("target", "java");
    }
    return map(
        "main", main,
        "feature", map("test", map()),
        "options", map(
            "base", "http://localhost:8000",
            "auth", map("prefix", ""),
            "entity", map("todo", map())),
        "entity", map("todo", map(
            "name", "todo",
            "fields", List.of(map("name", "title", "kind", "String")),
            "op", map("list", map("points", List.of(map(
                "method", "GET",
                "orig", "/api/todo",
                "parts", List.of("api", "todo"))))))));
  }

  static Map<String, Object> bind(Station st, Object client, Map<String, Object> options) {
    Map<String, Object> fopts = Descriptor.asmap(
        Descriptor.getprop(options.get("feature"), "station"));
    return st.featureBinding(client,
        List.of("station"), null, sdkconfig("TestPlug", "test-plug"), options, fopts);
  }

  // --- a generated-SDK stand-in for the declarative front door ---

  // The embedded config a generated `pad` SDK would carry: three features
  // with DECLARED OPTIONS, which is the schema the design 8.5 checker
  // validates against.
  static Map<String, Object> padconfig() {
    return map(
        "main", map("name", "Pad", "slug", "pad", "version", "0.0.1",
            "target", "java"),
        "feature", map(
            "retry", map("options", map("retries", 3L, "wait", 100L)),
            "ratelimit", map("options", map("rate", 1L, "burst", 1L)),
            "debug", map("options", map("level", 1L)),
            "test", map()),
        "options", map("base", "http://localhost:8000", "auth", map("prefix", "")),
        "entity", map());
  }

  /** A client the factory table can construct: it binds like a real one. */
  public static final class PadSDK {
    public final Map<String, Object> options;
    public final Map<String, Object> binding;

    public PadSDK(Map<String, Object> options) {
      this.options = options;
      Map<String, Object> fopts = Descriptor.asmap(
          Descriptor.getprop(options.get("feature"), "station"));
      Station st = Station.from(fopts);
      this.binding = null == st ? null : st.featureBinding(this,
          List.of("station"), null, padconfig(), options, fopts);
    }
  }

  static final Object PADCONFIG = padconfig();

  static Factory padfactory() {
    return new Factory(PadSDK::new, PADCONFIG);
  }

  /**
   * Path 1 of design 6.2 in the java spelling: a ServiceLoader registrar,
   * named by test/resources/META-INF/services. A java `import` runs no
   * static initializer, so this - not an import - is what "the package
   * self-registers" means here.
   */
  public static final class SvcRegistrar implements Factory.Registrar {
    public SvcRegistrar() {}

    @Override
    public String api() {
      return "svcdemo";
    }

    @Override
    public Factory factory() {
      return new Factory(PadSDK::new, PADCONFIG);
    }
  }

  public static void main(String[] args) {
    if (0 < args.length) {
      only = args[0];
    }

    RunPack R = Runner.makeRunner(specfile("station.json"), null).runner("station");

    // The shared corpus (design 13), REGISTERED FROM THE TABLE.
    for (Driver driver : DRIVERS) {
      testcase(driver.name, () -> {
        Object set = R.set(driver.name);
        check(null != set, "corpus section missing: " + driver.name);
        R.runset(set, driver.subject);
      });
    }

    // The completeness guard. It reads the corpus file DIRECTLY as raw
    // JSON, not through the omni runner: the runner resolves and
    // normalizes a NAMED section, so it would hide a section it never
    // resolved. A section added to the corpus and not picked up here
    // appears in `present` and not in `covered` and fails loudly instead
    // of silently not running; a section renamed or deleted while this port
    // still lists it fails the other way, so a stale driver or a stale
    // PENDING pin is caught rather than rotting.
    testcase("sections-covered", () -> {
      Object spec = parsefile(specfile("station.json"));
      Map<String, Object> sections = Descriptor.asmap(
          Descriptor.getprop(Descriptor.getprop(spec, "primary"), "station"));
      check(!sections.isEmpty(), "spec has primary.station sections");

      List<String> present = new ArrayList<>(new TreeSet<>(sections.keySet()));

      TreeSet<String> coveredset = new TreeSet<>();
      for (Driver driver : DRIVERS) {
        coveredset.add(driver.name);
      }
      for (String[] pending : PENDING) {
        coveredset.add(pending[0]);
      }
      List<String> covered = new ArrayList<>(coveredset);

      checkeq(present, covered, "corpus sections not covered");
    });

    // --- the shape artifact (design 4.3) ---

    testcase("shape: the mirror has not drifted", () -> {
      Object spec = parsefile(specfile("config-shape.json"));
      checkeq(Descriptor.canonicalSerialize(Shape.configShape()),
          Descriptor.canonicalSerialize(spec),
          "the classpath config shape has drifted from spec/config-shape.json "
              + "- run `make sync-shape`");
    });

    // Every validate must get a FRESH DEEP COPY: struct's validator
    // CONSUMES the spec it walks - it deletes satisfied `$ONE` branches as
    // it goes - so handing it one parsed constant twice validates the
    // second config against a spec the first already ate.
    testcase("shape: a fresh deep copy on every call", () -> {
      checkeq(Descriptor.canonicalSerialize(Shape.configShape()),
          Descriptor.canonicalSerialize(Shape.configShape()), "two copies agree");
      Map<String, Object> config = map("station", 1, "profiles", map(
          "default", map("sdk", map("solar", map("base", "http://x:1")))));
      for (int run = 0; run < 3; run++) {
        Shape.validateConfig(Shape.normalizeConfig(config));
      }
    });

    testcase("shape: the two block specs are identical", () -> {
      Map<String, Object> shape = Descriptor.asmap(Shape.configShape());
      Object profile = Descriptor.getprop(
          Descriptor.getprop(shape, "profiles"), "`$CHILD`");
      Object api = Descriptor.getprop(
          Descriptor.getprop(profile, "api"), "`$CHILD`");
      Object sdk = Descriptor.getprop(
          Descriptor.getprop(profile, "sdk"), "`$CHILD`");
      checkeq(Descriptor.canonicalSerialize(api), Descriptor.canonicalSerialize(sdk),
          "an api block and an sdk block are the same grammar (3.4)");
    });

    testcase("shape: MERGE_SENSITIVE names the non-container defaults", () -> {
      checkeq(Shape.MERGE_SENSITIVE, List.of("active"), "exactly ['active']");
      Map<String, ?> defaults = Shape.blockDefaults();
      for (String key : Shape.MERGE_SENSITIVE) {
        check(defaults.containsKey(key), "merge-sensitive " + key + " has a default");
      }
      // Every default that is not a CONTAINER is merge-sensitive: a
      // container merges as empty whether or not it was materialized early,
      // a scalar does not.
      for (Map.Entry<String, ?> e : Shape.blockDefaults().entrySet()) {
        Object made = ((java.util.function.Supplier<Object>) e.getValue()).get();
        if (made instanceof Map || made instanceof List) {
          continue;
        }
        check(Shape.MERGE_SENSITIVE.contains(e.getKey()),
            "scalar block default " + e.getKey() + " must be merge-sensitive (3.3)");
      }
    });

    testcase("shape: `$OPEN` is only the three feature entries", () -> {
      List<String> open = new ArrayList<>();
      openpaths(Shape.configShape(), "", open);
      java.util.Collections.sort(open);
      checkeq(open, List.of(
          "profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`",
          "profiles.`$CHILD`.feature.`$CHILD`",
          "profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`"),
          "a feature entry is the one place a foreign grammar passes through");
    });

    testcase("normalize: the input is never mutated", () -> {
      Map<String, Object> raw = map("station", 1, "profiles", map(
          "default", map("sdk", map("solar", map()))));
      String before = Descriptor.canonicalSerialize(raw);
      Object out = Shape.normalizeConfig(raw);
      checkeq(Descriptor.canonicalSerialize(raw), before, "raw untouched");
      check(Boolean.TRUE.equals(Descriptor.getprop(Descriptor.getprop(
          Descriptor.getprop(Descriptor.getprop(Descriptor.getprop(
              out, "profiles"), "default"), "sdk"), "solar"), "active")),
          "the copy carries the default");
    });

    // --- the factory table (design 6.2) ---

    testcase("factory: idempotent for one pair, loud for two", () -> {
      Factory.resetFactories();
      try {
        Factory factory = padfactory();
        Factory.Entry first = Factory.provide("pad", factory);
        check(first == Factory.provide("pad", factory), "same pair is a no-op");
        check("pad".equals(first.descriptor.get("slug")),
            "the descriptor is normalized AT PROVIDE TIME");
        check(Factory.provided().contains("pad"), "provided() lists it");
        try {
          // A DIFFERENT pair: java caches a non-capturing method reference
          // per site, so the constructor half alone would still be
          // identical - the config is what differs here, and either half
          // differing is a conflict.
          Factory.provide("pad", new Factory(PadSDK::new, padconfig()));
          check(false, "a different factory must be refused");
        } catch (StationError err) {
          checkeq(err.code, "station_factory_conflict", "conflict code");
        }
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("factory: a ServiceLoader registrar self-registers", () -> {
      Factory.resetFactories();
      try {
        // No import runs this: the META-INF/services entry does. That IS
        // path 1 in java (design 6.2, and the 5.4 note that a java import
        // loads nothing).
        Factory.Entry entry = Factory.factoryFor("svcdemo");
        check(null != entry, "the classpath registrar filled the table");
        checkeq(entry.api, "svcdemo", "its api");
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("loader: checkPackage takes module names and nothing else", () -> {
      checkeq(Loader.checkPackage("pad", "@acme-sdk/pad-sdk"),
          "@acme-sdk/pad-sdk", "a bare module name passes");
      for (Object bad : Arrays.asList("", "./local", "/abs", "~/home",
          "https://x/y", "a\\b", "pkg/../../escape", 7L, null)) {
        try {
          Loader.checkPackage("pad", bad);
          check(false, "must reject: " + bad);
        } catch (StationError err) {
          checkeq(err.code, "station_sdk_load", "load code for " + bad);
        }
      }
      checkeq(Loader.camelify("stripe-eu"), "StripeEu", "camelify");
    });

    // --- the declarative front door (design 6) ---

    testcase("front door: sdk() caches, create() auto-tags", () -> {
      Factory.resetFactories();
      try {
        Station.provide("pad", padfactory());
        Station st = memoryStation(map("PAD_APIKEY", "k"),
            map("pad", map(), "pad$eu", map("base", "https://eu.pad")));

        Object one = st.sdk("pad");
        check(one == st.sdk("pad"), "sdk() caches by name");
        checkeq(((PadSDK) one).binding.get("plugin"), "pad", "registered by instance");

        Object eu = st.sdk("pad$eu");
        check(one != eu, "a second instance is a second client");
        checkeq(((PadSDK) eu).options.get("base"), "https://eu.pad",
            "the declared base reaches the constructor");

        Object fresh = st.create("pad");
        check(fresh != one, "create() is UNCACHED");
        checkeq(((PadSDK) fresh).binding.get("plugin"), "pad$1", "auto-tagged");
        checkeq(st.declaredRef("pad$1"), "pad", "the tag stands for the declaration");
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("front door: autotag skips a DECLARED tag, not just a live one", () -> {
      Factory.resetFactories();
      try {
        Station.provide("pad", padfactory());
        Station st = memoryStation(map("PAD_APIKEY", "k"),
            map("pad", map(), "pad$1", map()));
        checkeq(st.autotag("pad"), "pad$2",
            "declaration reserves the name whether or not it has been built");
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("front door: the availability errors", () -> {
      Factory.resetFactories();
      try {
        Station st = memoryStation(map(),
            map("pad", map(), "pad$off", map("active", false)));
        try {
          st.sdk("nope");
          check(false, "an undeclared name must fail");
        } catch (StationError err) {
          checkeq(err.code, "station_no_instance", "no instance code");
        }
        try {
          st.sdk("pad$off");
          check(false, "an inactive instance must fail");
        } catch (StationError err) {
          checkeq(err.code, "station_instance_inactive", "inactive code");
        }
        try {
          st.sdk("pad");
          check(false, "no factory must fail");
        } catch (StationError err) {
          checkeq(err.code, "station_no_factory", "no factory code");
          check(err.getMessage().contains("`package` is not honoured"),
              "the message names only the remedies java offers (5.4)");
        }
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("front door: an auto-tagged client keeps the declared policy", () -> {
      Factory.resetFactories();
      try {
        Station.provide("pad", padfactory());
        Station st = memoryStation(map("PAD_PROD_APIKEY", "k"),
            map("pad$prod", map("policy", map("hosts", List.of("api.good.example")))),
            map("pad", map("policy", map("hosts", List.of("wide.example")))));
        st.create("pad$prod");
        // THE ALIAS IS RECORDED, NOT THE FIELDS: blockFor walks it, so the
        // narrow allowlist follows the tag instead of falling back to the
        // wider api-level one.
        checkeq(Descriptor.getprop(
            Descriptor.getprop(st.blockFor("pad$1"), "policy"), "hosts"),
            List.of("api.good.example"), "the declared instance's hosts");
        try {
          st.transport("pad$1", "http://wide.example/x", map("headers", map()),
              true, null, (url, def) -> map("status", 200));
          check(false, "off-list egress must be denied");
        } catch (StationError err) {
          checkeq(err.code, "station_host_allow", "host code");
        }
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("front door: featuresOf merges, provenances, and composes the budget", () -> {
      Factory.resetFactories();
      try {
        Map<String, Object> config = map("station", 1, "profiles", map(
            "default", map(
                "secrets", map("providers", List.of(map("kind", "memory",
                    "values", map("PAD_APIKEY", "k")))),
                "feature", map("retry", map("retries", 1)),
                "api", map("pad", map("feature", map("retry", map("wait", 50)))),
                "sdk", map("pad", map(
                    "feature", map("retry", map("retries", 4)),
                    "policy", map("budget", map("rps", 7, "concurrency", 3)))))));
        Station st = new Station(map("config", config));

        Map<String, Object> resolved = st.featuresOf("pad");
        Map<String, Object> merged = Descriptor.asmap(resolved.get("merged"));
        checkeq(Descriptor.getprop(merged.get("retry"), "retries"), 4,
            "the narrower block wins");
        checkeq(Descriptor.getprop(merged.get("retry"), "wait"), 50,
            "per-key union across levels");
        checkeq(Descriptor.getprop(merged.get("ratelimit"), "rate"), 7,
            "policy.budget.rps composes as ratelimit.rate");
        checkeq(Descriptor.getprop(merged.get("ratelimit"), "burst"), 3,
            "policy.budget.concurrency composes as ratelimit.burst");

        Map<String, Object> from = Descriptor.asmap(resolved.get("from"));
        checkeq(Descriptor.getprop(from.get("retry"), "retries"), "default.sdk",
            "provenance names the level that wrote it");
        checkeq(Descriptor.getprop(from.get("retry"), "wait"), "default.api",
            "and the level that wrote the other key");
        checkeq(Descriptor.getprop(from.get("ratelimit"), "rate"), "policy.budget",
            "policy provenance");

        // `station` is never in `merged` - it is added for ORDERING ONLY.
        check(!merged.containsKey("station"), "merged stays the user's own merge");
        check(((List<Object>) resolved.get("ordered")).contains("station"),
            "the implicit station row is reported in the order");
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("front door: features(filter) narrows the rows to the feature", () -> {
      Map<String, Object> config = map("station", 1, "profiles", map(
          "default", map(
              "secrets", map("providers", List.of(map("kind", "memory",
                  "values", map())))),
          "sdk", map()));
      ((Map<String, Object>) Descriptor.getprop(config, "profiles"))
          .put("default", map(
              "secrets", map("providers", List.of(map("kind", "memory",
                  "values", map()))),
              "sdk", map(
                  "pad", map("feature", map("debug", map("level", 2))),
                  "solar", map("feature", map("retry", map("retries", 2))))));
      Station st = new Station(map("config", config));

      Station.FeatureFilter want = new Station.FeatureFilter();
      want.feature = "debug";
      List<Map<String, Object>> rows = st.features(want);
      checkeq(rows.size(), 1, "only the instance carrying it");
      checkeq(rows.get(0).get("instance"), "pad", "which instance");
      checkeq(Descriptor.asmap(rows.get(0).get("merged")).keySet().toString(),
          "[debug]", "narrowed to the one feature");

      checkeq(st.features(Station.looseFilter("solar")).size(), 1,
          "the string shorthand matches an instance or its api");
    });

    testcase("front door: check() catches a feature typo without constructing", () -> {
      Factory.resetFactories();
      try {
        Station.provide("pad", padfactory());
        Map<String, Object> config = map("station", 1, "profiles", map(
            "default", map(
                "secrets", map("providers", List.of(map("kind", "memory",
                    "values", map("PAD_APIKEY", "k"))))),
                "sdk", map()));
        ((Map<String, Object>) Descriptor.getprop(config, "profiles"))
            .put("default", map(
                "secrets", map("providers", List.of(map("kind", "memory",
                    "values", map("PAD_APIKEY", "k")))),
                "sdk", map(
                    "pad", map("feature", map("retry", map("retires", 5))),
                    "pad$ok", map())));
        Station st = new Station(map("config", config));

        Map<String, Object> report = st.check();
        checkeq((List<Object>) report.get("ok"), List.of("pad$ok"), "the good one");
        List<Map<String, Object>> failed =
            (List<Map<String, Object>>) report.get("failed");
        checkeq(failed.size(), 1, "one failure");
        checkeq(failed.get(0).get("code"), "station_feature_option", "option code");
        check(String.valueOf(failed.get(0).get("message"))
            .contains("declares no option \"retires\""), "names the typo");
        check(!st.instances().isEmpty(), "nothing was constructed for the bad one");

        // ...and sdk() itself refuses it too, because EVERY path to a
        // constructor goes through build().
        try {
          st.sdk("pad");
          check(false, "sdk() must refuse an unknown feature option");
        } catch (StationError err) {
          checkeq(err.code, "station_feature_option", "same code on the hot path");
        }
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("front door: warm dedupes by secret name; an unknown name is a miss", () -> {
      Station st = memoryStation(map("PAD_APIKEY", "k", "SHARED_APIKEY", "s"),
          map("pad", map(),
              "pad$a", map("secret", "shared.apikey"),
              "pad$b", map("secret", "shared.apikey"),
              "pad$gone", map()));
      Map<String, Object> out = st.warm();
      checkeq(out.get("warmed"), List.of("pad", "pad$a", "pad$b"), "warmed, sorted");
      checkeq(out.get("missed"), List.of("pad$gone"),
          "an instance with no stored credential is a miss");

      Map<String, Object> typo = st.warm(List.of("pad$prodd"));
      checkeq(typo.get("missed"), List.of("pad$prodd"),
          "a name nobody declared is a MISS, never a lookup");
      checkeq(typo.get("warmed"), List.of(), "and nothing is warmed off a sibling");
    });

    testcase("front door: instances() reports declared, plugins() reports live", () -> {
      Factory.resetFactories();
      try {
        Station.provide("pad", padfactory());
        Station st = memoryStation(map("PAD_APIKEY", "k"),
            map("pad", map(), "pad$off", map("active", false)));
        List<Map<String, Object>> rows = st.instances();
        checkeq(rows.size(), 2, "both declared");
        checkeq(rows.get(0).get("name"), "pad", "sorted by name");
        checkeq(rows.get(0).get("live"), false, "not yet live");
        checkeq(rows.get(1).get("active"), false, "barred but visible");

        st.sdk("pad");
        checkeq(st.instances().get(0).get("live"), true, "live after construction");
        checkeq(st.plugins().size(), 1, "one live instance");
        checkeq(st.plugins().get(0).get("api"), "pad", "grouped by api");
        checkeq(st.plugins().get(0).get("secretname"), "pad.apikey",
            "the effective secret name is on the entry");
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("binding: two instances of one api get distinct placeholders", () -> {
      Factory.resetFactories();
      try {
        Station.provide("pad", padfactory());
        Station st = memoryStation(map("PAD_APIKEY", "k", "PAD_EU_APIKEY", "e"),
            map("pad", map(), "pad$eu", map()));
        PadSDK one = (PadSDK) st.sdk("pad");
        PadSDK eu = (PadSDK) st.sdk("pad$eu");
        checkeq(one.binding.get("placeholder"), "[station:pad]", "untagged");
        checkeq(eu.binding.get("placeholder"), "[station:pad$eu]", "tagged");
        checkeq(eu.binding.get("secretname"), "pad_eu.apikey",
            "the secret name follows the INSTANCE, not the api");
      } finally {
        Factory.resetFactories();
      }
    });

    testcase("open: a malformed config fails with every error at once", () -> {
      Map<String, Object> config = map("station", 1, "profiles", map(
          "default", map("sdk", map(
              "a", map("bass", 1), "b", map("tuba", 2), "c", map("oboe", 3)))));
      try {
        new Station(map("config", config));
        check(false, "open() must refuse a malformed config");
      } catch (StationError err) {
        checkeq(err.code, "station_config_invalid", "invalid code");
        String message = err.getMessage();
        check(message.contains("sdk.a: bass") && message.contains("sdk.b: tuba")
            && message.contains("sdk.c: oboe"), "EVERY error at once");
      }
    });

    testcase("open: repoScoped reads the explicit option first", () -> {
      Station inferred = new Station(map("config", map("station", 1)));
      check(inferred.repoScoped, "an in-code config is repo-scoped by construction");
      Station explicit = new Station(
          map("config", map("station", 1), "repoScoped", false));
      check(!explicit.repoScoped,
          "the explicit option is settable for an in-code config");
    });

    // --- focused unit cases: the mechanics the corpus cannot reach ---

    testcase("events: ring overflow drops oldest, counted", () -> {
      EventBuffer buffer = new EventBuffer(2);
      buffer.emit(map("t", 1L, "kind", "station"));
      buffer.emit(map("t", 2L, "kind", "station"));
      buffer.emit(map("t", 3L, "kind", "station"));
      List<Map<String, Object>> events = buffer.events();
      check(2 == events.size(), "ring bounded");
      check(2L == (Long) events.get(0).get("t"), "oldest dropped");
      check(1L == (Long) buffer.status().get("dropped"), "drop counted");
    });

    testcase("events: a throwing tap never fails the emitter", () -> {
      EventBuffer buffer = new EventBuffer();
      List<Object> seen = new ArrayList<>();
      buffer.tap(ev -> { throw new RuntimeException("tap boom"); });
      Runnable off = buffer.tap(seen::add);
      buffer.emit(map("kind", "station"));
      check(1 == seen.size(), "tap saw the event");
      off.run();
      buffer.emit(map("kind", "station"));
      check(1 == seen.size(), "unsubscribed");
    });

    testcase("broker: miss is station_secret_no_value, scrub has no floor", () -> {
      SecretBroker broker = new SecretBroker(List.of(
          map("kind", "memory", "values", map("A_APIKEY", "xy"))));
      check("xy".equals(broker.value("a", "a.apikey")), "resolves");
      // Exact-value scrub, even below sekreto's four-character floor.
      check("k=[redacted];".equals(broker.scrub("k=xy;")), "floor-less scrub");
      try {
        broker.value("b", "b.apikey");
        check(false, "miss should throw");
      } catch (StationError err) {
        check("station_secret_no_value".equals(err.code), "miss code");
      }
    });

    testcase("broker: the resolution cache is keyed by SECRET NAME", () -> {
      SecretBroker broker = new SecretBroker(List.of(
          map("kind", "memory", "values", map("SHARED_APIKEY", "s"))));
      check("s".equals(broker.value("pad$a", "shared.apikey")), "first instance");
      // A second instance sharing one api-level `secret` costs no second
      // round-trip - and a hoisted override still belongs to its own
      // instance.
      broker.hoist("pad$c", "resident");
      check("s".equals(broker.value("pad$b", "shared.apikey")), "cached by name");
      check("resident".equals(broker.value("pad$c", "shared.apikey")),
          "the override is keyed by instance");
    });

    testcase("open: idempotent ambient, conflicting reopen fails", () -> {
      Station.reset();
      try {
        Station one = Station.open(map("config", (Object) null));
        check(one == Station.open(map("config", (Object) null)), "same instance");
        check(one == Station.current(), "current() is the ambient");
        try {
          Station.open(map("config", (Object) null, "profile", "prod"));
          check(false, "conflicting open must fail");
        } catch (StationError err) {
          check("station_open_conflict".equals(err.code), "conflict code");
        }
        one.close();
        check(null == Station.current(), "close() of the ambient resets it");
      } finally {
        Station.reset();
      }
    });

    testcase("options: activation entry carries the handle", () -> {
      Station st = memoryStation(map(), null);
      Map<String, Object> options = st.options(map("base", "http://x:1"));
      Map<String, Object> entry = Descriptor.asmap(
          Descriptor.getprop(options.get("feature"), "station"));
      check(Boolean.TRUE.equals(entry.get("active")), "active");
      check(st == entry.get("station"), "handle rides the options");
      check("http://x:1".equals(options.get("base")), "caller opts kept");
      check(null == entry.get("instance"), "no instance name on the bare form");

      // Design 6.1: the name is OPTIONAL AND LEADING, so the existing
      // one-argument call above is unchanged.
      Map<String, Object> named = st.options("pad$eu", map());
      check("pad$eu".equals(Descriptor.getprop(
          Descriptor.getprop(named.get("feature"), "station"), "instance")),
          "the leading name reaches the adapter");
    });

    testcase("binding: registers, plants placeholder, hoists a resident key", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "real-key-1"), null);
      Object client = new Object();
      Map<String, Object> options = st.options(map());
      options.put("apikey", "resident-key");
      Map<String, Object> binding = bind(st, client, options);
      check("test-plug".equals(binding.get("plugin")), "instance");
      check("R1".equals(binding.get("rung")), "rung");
      check("[station:test-plug]".equals(options.get("apikey")), "placeholder planted");
      boolean warned = false;
      for (Map<String, Object> ev : st.events()) {
        Object meta = ev.get("meta");
        warned = warned || (null != meta
            && String.valueOf(Descriptor.getprop(meta, "warn")).contains("hoisted"));
      }
      check(warned, "hoist warning emitted");
      check("x [redacted] y".equals(st.redact("x resident-key y")), "hoisted value scrubbed");
      // Same client, second arrival: inert.
      check(null == bind(st, client, options), "idempotent per client");
      // A second binding of the SAME INSTANCE: refused.
      try {
        bind(st, new Object(), st.options(map()));
        check(false, "second client must fail");
      } catch (StationError err) {
        check("station_bound_twice".equals(err.code), "bound twice code");
      }
    });

    testcase("binding: wrong wrap position fails loudly", () -> {
      Station st = memoryStation(map(), null);
      try {
        st.featureBinding(new Object(), List.of("test", "retry", "station"),
            null, sdkconfig("TestPlug", "test-plug"), map("feature", map()), map());
        check(false, "order guard must trip");
      } catch (StationError err) {
        check("station_wrap_order".equals(err.code), "order code");
      }
    });

    testcase("binding: policy.allow is enforcement, not a default", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "k"), map(
          "test-plug", map("policy", map(
              "allow", map("op", List.of("list", "load"),
                  "method", List.of("GET"))))));
      Map<String, Object> options = st.options(map("allow", "everything"));
      bind(st, new Object(), options);
      check("list,load".equals(options.get("allow")), "policy wins on the keys it sets");
      check("GET".equals(options.get("allowmethod")), "and on the method list");
    });

    testcase("transport: copy-on-inject swaps only the sent copy", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "real-key-2"), null);
      Map<String, Object> options = st.options(map());
      bind(st, new Object(), options);

      Map<String, Object> headers = map("authorization", "[station:test-plug]");
      Map<String, Object> fetchdef = map("method", "GET", "headers", headers);
      List<Object> sent = new ArrayList<>();
      Object res = st.transport("test-plug", "http://localhost:8000/api/todo",
          fetchdef, true, "c1", (url, def) -> {
            sent.add(Descriptor.getprop(def.get("headers"), "authorization"));
            return map("status", 200, "headers", map("content-length", "12"));
          });
      check("real-key-2".equals(sent.get(0)), "real value on the wire");
      check("[station:test-plug]".equals(headers.get("authorization")),
          "caller's fetchdef keeps the placeholder");
      check(res instanceof Map, "response returned");

      List<Map<String, Object>> events = st.events();
      Map<String, Object> http = null;
      for (Map<String, Object> ev : events) {
        if ("http".equals(ev.get("kind"))) {
          http = ev;
        }
      }
      check(null != http, "http event emitted");
      check("c1".equals(http.get("corr")), "correlated");
      check("test-plug".equals(http.get("api")), "every kind carries api too");
      Map<String, Object> hm = Descriptor.asmap(http.get("http"));
      check(Integer.valueOf(200).equals(hm.get("status")), "wire status");
      check(Long.valueOf(12L).equals(hm.get("bytes")), "bytes from content-length");
    });

    testcase("transport: no injection into mock transports", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "real-key-3"), null);
      bind(st, new Object(), st.options(map()));
      List<Object> sent = new ArrayList<>();
      st.transport("test-plug", "http://localhost:8000/api/todo",
          map("headers", map("authorization", "[station:test-plug]")),
          false, null, (url, def) -> {
            sent.add(Descriptor.getprop(def.get("headers"), "authorization"));
            return map("status", 200);
          });
      check("[station:test-plug]".equals(sent.get(0)),
          "placeholder rides through untouched in mock mode");
    });

    testcase("transport: a missing secret fails the op with the code", () -> {
      Station st = memoryStation(map(), null);
      bind(st, new Object(), st.options(map()));
      try {
        st.transport("test-plug", "http://localhost:8000/api/todo",
            map("headers", map()), true, null, (url, def) -> map("status", 200));
        check(false, "missing secret must throw");
      } catch (StationError err) {
        check("station_secret_no_value".equals(err.code), "miss code");
      }
      boolean recorded = false;
      for (Map<String, Object> ev : st.events()) {
        recorded = recorded || ("error".equals(ev.get("kind"))
            && "station_secret_no_value".equals(Descriptor.getprop(ev.get("err"), "code")));
      }
      check(recorded, "error event recorded");
    });

    testcase("transport: hosts policy denies off-list egress, live only", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "k"), map(
          "test-plug", map("policy", map("hosts", List.of("api.good.example")))));
      bind(st, new Object(), st.options(map()));
      try {
        st.transport("test-plug", "http://evil.example/x",
            map("headers", map()), true, null, (url, def) -> map("status", 200));
        check(false, "off-list host must be denied");
      } catch (StationError err) {
        check("station_host_allow".equals(err.code), "host code");
      }
      // A mock-transport call is not egress; the policy does not fire.
      Object res = st.transport("test-plug", "http://evil.example/x",
          map("headers", map()), false, null, (url, def) -> map("status", 200));
      check(res instanceof Map, "mock path unaffected");
    });

    testcase("transport: manual redirects ride the sent copy under a hosts policy", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "k"), map(
          "test-plug", map("policy", map("hosts", List.of("api.good.example")))));
      bind(st, new Object(), st.options(map()));
      Map<String, Object> fetchdef = map("headers", map());
      List<Object> sent = new ArrayList<>();
      st.transport("test-plug", "http://api.good.example/x",
          fetchdef, true, null, (url, def) -> {
            sent.add(def.get("redirect"));
            return map("status", 200);
          });
      check("manual".equals(sent.get(0)), "redirect: manual on the sent copy");
      check(null == fetchdef.get("redirect"), "caller's fetchdef untouched");
    });

    testcase("transport: require-proxy fails closed on the operation path", () -> {
      Station st = new Station(map("config", (Object) null, "proxy", "require"));
      try {
        st.transport("any", "http://localhost:1/x", map(), true, null,
            (url, def) -> map("status", 200));
        check(false, "require must fail traffic");
      } catch (StationError err) {
        check("station_no_proxy".equals(err.code), "no proxy code");
      }
    });

    testcase("open: `package` is warned about once per api, never honoured", () -> {
      Station st = memoryStation(map(),
          map("pad", map(), "pad$eu", map()),
          map("pad", map("package", "@acme-sdk/pad-sdk")));
      int warns = 0;
      for (Map<String, Object> ev : st.events()) {
        if (String.valueOf(Descriptor.getprop(ev.get("meta"), "warn"))
            .contains("`package` is not honoured")) {
          warns++;
        }
      }
      checkeq(warns, 1, "one event per api, at open, once (5.4 item 2)");
      check(null == st.loaderPackage("pad", map("package", "x")),
          "loaderPackage is always null here");
      st.load();
    });

    System.out.println("\n" + passcount + " passed, " + failcount + " failed");
    System.exit(0 == failcount ? 0 : 1);
  }

  static void openpaths(Object node, String path, List<String> out) {
    if (node instanceof Map) {
      for (Map.Entry<String, Object> e : ((Map<String, Object>) node).entrySet()) {
        if ("`$OPEN`".equals(e.getKey())) {
          out.add(path);
        }
        openpaths(e.getValue(), path.isEmpty() ? e.getKey() : path + "." + e.getKey(), out);
      }
      return;
    }
    if (node instanceof List) {
      List<Object> list = (List<Object>) node;
      for (int index = 0; index < list.size(); index++) {
        openpaths(list.get(index),
            path.isEmpty() ? String.valueOf(index) : path + "." + index, out);
      }
    }
  }
}
