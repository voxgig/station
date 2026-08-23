// RUN: make test
// RUN-SOME: java -cp ... StationTest secretname
//
// The station conformance suite: the pure-contract half of the design's
// (13) corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery (inject,
// order, event correlation) live in the consumer end-to-end suites
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present. The focused unit cases below cover the station
// mechanics the corpus cannot reach without an SDK: the event ring, the
// broker's miss-vs-error and floor-less scrub, the binding guards, and
// the transport middleware's copy-on-inject.
//
// No third-party test framework: a failing omni check throws OmniError,
// so `make test` stays dependency-free (the sekreto/omni pattern).

import com.voxgig.omni.Runner;
import com.voxgig.omni.Runner.OmniError;
import com.voxgig.omni.Runner.RunPack;
import com.voxgig.omni.Runner.Subject;

import com.voxgig.sekreto.Sekreto;

import com.voxgig.station.Descriptor;
import com.voxgig.station.EventBuffer;
import com.voxgig.station.Profile;
import com.voxgig.station.SecretBroker;
import com.voxgig.station.Station;
import com.voxgig.station.StationError;

import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

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
  // serializer sees what the spec means.
  @SuppressWarnings("unchecked")
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

  static final Subject CANONICAL = args ->
      Descriptor.canonicalSerialize(denull(args[0]));

  static final Subject INSTANCE = args -> {
    Map<?, ?> vin = (Map<?, ?>) args[0];
    return Profile.resolveProfile(vin.get("config"), String.valueOf(vin.get("profile")));
  };

  static final Subject ERRORS = args -> StationError.isKnownCode(args[0]);

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
    Map<String, Object> profile = map(
        "secrets", map("providers", List.of(map("kind", "memory", "values", values))));
    if (null != plugin) {
      profile.put("sdk", plugin);
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

  public static void main(String[] args) {
    if (0 < args.length) {
      only = args[0];
    }

    RunPack R = Runner.makeRunner(specfile("station.json"), null).runner("station");

    // The shared corpus (design 13).
    testcase("secretname", () -> R.runset(R.set("secretname"), SECRETNAME));
    testcase("placeholder", () -> R.runset(R.set("placeholder"), PLACEHOLDER));
    testcase("descriptor", () -> R.runset(R.set("descriptor"), DESCRIPTOR));
    testcase("descriptorwarnings", () -> R.runset(R.set("descriptorwarnings"), DESCWARN));
    testcase("canonical", () -> R.runset(R.set("canonical"), CANONICAL));
    // The 3.3 merge, and the whole of this port's profile contract. The
    // `profile` section is NOT run: it pins the pre-Stage-1 `plugin`
    // grammar, which this port no longer speaks. It stays in the corpus
    // for the ports that have not crossed yet - see spec/README.md.
    testcase("instance", () -> R.runset(R.set("instance"), INSTANCE));
    testcase("errors", () -> R.runset(R.set("errors"), ERRORS));

    // Focused unit cases: the mechanics the corpus cannot reach.

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
    });

    testcase("binding: registers, plants placeholder, hoists a resident key", () -> {
      Station st = memoryStation(map("TEST_PLUG_APIKEY", "real-key-1"), null);
      Object client = new Object();
      Map<String, Object> options = st.options(map());
      options.put("apikey", "resident-key");
      Map<String, Object> binding = bind(st, client, options);
      check("test-plug".equals(binding.get("plugin")), "slug");
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
      // A second client of the same SDK: refused.
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

    System.out.println("\n" + passcount + " passed, " + failcount + " failed");
    System.exit(0 == failcount ? 0 : 1);
  }
}
