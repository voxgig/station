// RUN: make test          (or: ./build/unit [testname])
//
// Focused unit tests for the parts of the C++ station library the
// conformance corpus cannot reach standalone: the event ring, the
// env-only secret broker, the ambient instance contract, registration,
// and profile-file loading. The SDK seam (feature_binding, transport
// middleware, injection) is exercised inside generated SDKs.

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "../src/voxgig_station.hpp"

namespace {

namespace vs = vstation;

std::string ONLY;
int PASSCOUNT = 0;
int FAILCOUNT = 0;

void testcase(const std::string& name, const std::function<void()>& body) {
  if (!ONLY.empty() && name != ONLY) {
    return;
  }
  vs::Station::reset();
  try {
    body();
    PASSCOUNT++;
    std::cout << "ok   - " << name << "\n";
  } catch (const std::exception& err) {
    FAILCOUNT++;
    std::cout << "FAIL - " << name << "\n  " << err.what() << "\n";
  }
  vs::Station::reset();
}

void check(bool ok, const std::string& what) {
  if (!ok) {
    throw std::runtime_error("check failed: " + what);
  }
}

void checkeq(const std::string& got, const std::string& want, const std::string& what) {
  if (got != want) {
    throw std::runtime_error("check failed: " + what + "\n    want: " + want +
                             "\n    got:  " + got);
  }
}

// The code of a StationError thrown by `body`, or '' when none thrown.
std::string thrown_code(const std::function<void()>& body) {
  try {
    body();
  } catch (const vs::StationError& e) {
    return e.code();
  }
  return "";
}

// A minimal modern embedded config, as Jval.
vs::Jval petconfig() {
  return vs::parse_json(R"({
    "main": { "name": "GnarlyPets", "slug": "gnarly-pets",
              "version": "0.0.1", "target": "cpp" },
    "feature": { "test": {} },
    "options": { "base": "http://localhost:8903",
                 "auth": { "prefix": "Bearer" }, "entity": { "pet": {} } },
    "entity": { "pet": { "fields": [ { "name": "name", "kind": "String" } ],
      "op": { "load": { "points": [ { "method": "GET",
        "orig": "/api/pet/:pet_id", "parts": ["api", "pet", ":pet_id"] } ] } } } }
  })");
}

// The shared spec directory, wherever this port is running from.
std::string specfile(const std::string& name) {
  std::filesystem::path dir = std::filesystem::current_path();
  for (int step = 0; step < 8; step++) {
    std::filesystem::path cand = dir / "spec" / name;
    if (std::filesystem::exists(cand)) {
      return cand.string();
    }
    if (!dir.has_parent_path() || dir == dir.parent_path()) {
      break;
    }
    dir = dir.parent_path();
  }
  return "";
}

// A stand-in generated constructor: it hands back the options station
// built, which is what the assertions below are about. A real one
// returns the SDK; the library cannot name that type, which is why a
// factory's client is a shared_ptr<void> (see ConstructFn).
vs::ConstructFn petconstruct() {
  return [](const vs::Jval& options) -> std::shared_ptr<void> {
    return std::make_shared<vs::Jval>(options);
  };
}

}  // namespace

int main(int argc, char** argv) {
  if (1 < argc) {
    ONLY = argv[1];
  }

  testcase("eventbuffer-ring-drop-oldest", [] {
    vs::EventBuffer buffer(3);
    for (int i = 0; i < 5; i++) {
      vs::Jval ev = vs::Jval::map();
      ev.set("t", vs::Jval::num(i));
      ev.set("kind", vs::Jval::str("station"));
      buffer.emit(ev);
    }
    auto events = buffer.events();
    check(3 == events.size(), "ring bounded");
    check(2.0 == events[0].get("t").nval, "oldest dropped");
    vs::Jval status = buffer.status();
    check(3.0 == status.get("buffered").nval, "buffered count");
    check(2.0 == status.get("dropped").nval, "drop count");
  });

  testcase("eventbuffer-tap-untap-and-throwing-tap", [] {
    vs::EventBuffer buffer;
    int seen = 0;
    auto untap = buffer.tap([&seen](const vs::Jval&) { seen++; });
    buffer.tap([](const vs::Jval&) { throw std::runtime_error("tap boom"); });
    vs::Jval ev = vs::Jval::map();
    ev.set("kind", vs::Jval::str("station"));
    buffer.emit(ev);  // the throwing tap must not fail the emit
    check(1 == seen, "tap called");
    untap();
    buffer.emit(ev);
    check(1 == seen, "untap stops delivery");
  });

  testcase("broker-env-resolution-and-miss", [] {
    setenv("UNIT_BROKER_APIKEY", "sk-live-x1", 1);
    vs::Jval providers = vs::parse_json(R"([{ "kind": "env" }])");
    vs::SecretBroker broker(providers);
    checkeq(broker.value("unit", "unit_broker.apikey"), "sk-live-x1", "env resolve");

    // A miss is not an error-shaped surprise: exact code, sekreto's
    // meaning (design 5.2).
    vs::SecretBroker broker2(providers);
    checkeq(thrown_code([&broker2] { broker2.value("unit", "unit_broker_absent.apikey"); }),
            "station_secret_no_value", "miss code");

    // Rotation: refresh drops the cache so the next resolve re-reads.
    setenv("UNIT_BROKER_APIKEY", "sk-live-x2", 1);
    checkeq(broker.value("unit", "unit_broker.apikey"), "sk-live-x1", "cached");
    broker.refresh();
    checkeq(broker.value("unit", "unit_broker.apikey"), "sk-live-x2", "refreshed");
    unsetenv("UNIT_BROKER_APIKEY");
  });

  testcase("broker-scrub-exact-value-no-floor", [] {
    setenv("UNIT_SCRUB_APIKEY", "xy", 1);  // BELOW sekreto's 4-char floor
    vs::Jval providers = vs::parse_json(R"([{ "kind": "env" }])");
    vs::SecretBroker broker(providers);
    broker.value("unit", "unit_scrub.apikey");
    checkeq(broker.scrub("token is xy here"), "token is [redacted] here",
            "short value scrubbed (no 4-char floor - design 7 as revised)");
    broker.hoist("other", "hoisted-secret");
    checkeq(broker.scrub("say hoisted-secret twice hoisted-secret"),
            "say [redacted] twice [redacted]", "hoisted value scrubbed everywhere");
    unsetenv("UNIT_SCRUB_APIKEY");
  });

  testcase("broker-unsupported-kinds-env-only", [] {
    vs::Jval providers = vs::parse_json(
        R"([{ "kind": "env" }, { "kind": "hashicorp", "addr": "https://v" },
            { "kind": "dotenv", "file": ".env" }])");
    vs::SecretBroker broker(providers);
    auto missing = broker.unsupported_kinds();
    check(2 == missing.size() && "dotenv" == missing[0] && "hashicorp" == missing[1],
          "non-env kinds reported");
  });

  testcase("ambient-open-idempotent-conflict-reset", [] {
    vs::StationOptions opts;
    opts.has_config = true;  // no station.json lookup
    auto a = vs::Station::open(opts);
    auto b = vs::Station::open(opts);
    check(a.get() == b.get(), "open is idempotent");
    check(vs::Station::current().get() == a.get(), "current is the ambient");

    vs::StationOptions other = opts;
    other.profile = "prod";
    checkeq(thrown_code([&other] { vs::Station::open(other); }), "station_open_conflict",
            "conflicting open refused");

    a->close();
    check(nullptr == vs::Station::current(), "close drops the ambient");
  });

  testcase("station-solo-warning-and-env-only-honesty", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "secrets": { "providers": [ { "kind": "hashicorp", "addr": "https://v" } ] } } } })");
    vs::Station st(opts);
    auto events = st.events();
    check(2 == events.size(), "two open warnings");
    check(std::string::npos !=
              events[0].get("meta").get("warn").sval.find("proxy absent"),
          "solo degrade warning");
    check(std::string::npos !=
              events[1].get("meta").get("warn").sval.find("env-only"),
          "env-only honesty warning");
    checkeq(st.status().get("secrets").str_or(""), "env-only", "status says env-only");
  });

  testcase("register-descriptor-duplicate-and-canonical", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    vs::Station st(opts);
    int client = 0;

    auto reg = st._register(&client, petconfig(), vs::Jval::absent());
    checkeq(reg.name, "gnarly-pets", "instance name");
    checkeq(reg.api, "gnarly-pets", "api");
    checkeq(reg.slug, "gnarly-pets", "slug");
    checkeq(reg.rung, "R1", "rung");
    checkeq(reg.placeholder, "[station:gnarly-pets]", "placeholder");
    checkeq(reg.secretname, "gnarly_pets.apikey", "secretname default");
    check(st._bound(&client), "client bound");

    int client2 = 0;
    checkeq(thrown_code([&] { st._register(&client2, petconfig(), vs::Jval::absent()); }),
            "station_bound_twice", "duplicate instance refused");

    std::string canonical = st.canonical_descriptor("gnarly-pets");
    check(0 == canonical.rfind("{\"auth\":", 0), "canonical keys sorted");
    check(std::string::npos != canonical.find("\"envtoken\":\"GNARLY_PETS\""),
          "canonical carries envtoken");

    checkeq(thrown_code([&st] { st.descriptor_of("nope"); }), "station_no_plugin",
            "unknown instance code");
  });

  testcase("register-secret-name-precedence", [] {
    vs::StationOptions o1;
    o1.has_config = true;
    o1.config = vs::parse_json(
        R"({ "station": 1, "profiles": { "default": {
             "sdk": { "gnarly-pets": { "secret": "profile.name" } } } } })");
    vs::Station st(o1);
    int c1 = 0;
    vs::Jval incode = vs::Jval::map();
    incode.set("secret", vs::Jval::str("code.name"));
    auto reg1 = st._register(&c1, petconfig(), incode);
    checkeq(reg1.secretname, "code.name", "feature option beats profile");

    vs::Station st2(o1);
    int c2 = 0;
    auto reg2 = st2._register(&c2, petconfig(), vs::Jval::absent());
    checkeq(reg2.secretname, "profile.name", "profile beats the instance default");

    // A TAGGED instance derives from the DECLARED ref, not the api, so
    // two live instances of one api never share a credential by
    // accident (design 5.1).
    vs::StationOptions o2;
    o2.has_config = true;
    o2.config = vs::parse_json(
        R"({ "station": 1, "profiles": { "default": {
             "sdk": { "gnarly-pets$eu": {} } } } })");
    vs::Station st3(o2);
    int c3 = 0;
    vs::Jval tagged = vs::Jval::map();
    tagged.set("instance", vs::Jval::str("gnarly-pets$eu"));
    auto reg3 = st3._register(&c3, petconfig(), tagged);
    checkeq(reg3.name, "gnarly-pets$eu", "tagged instance name");
    checkeq(reg3.secretname, "gnarly_pets_eu.apikey", "secret derives from the ref");
    checkeq(reg3.placeholder, "[station:gnarly-pets$eu]", "placeholder keys on the ref");
  });

  testcase("profile-bad-secret-name-at-load", [] {
    vs::Jval config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "sdk": { "a": { "secret": "Not A Name" } } } } })");

    // open() now VALIDATES FIRST (design 4.2), so the design 5.2 scan
    // reaches it before the profile resolver does - and for the whole
    // file at once rather than one instance at a time.
    vs::StationOptions opts;
    opts.has_config = true;
    opts.config = config;
    checkeq(thrown_code([&opts] { vs::Station st(opts); }), "station_config_secret",
            "malformed secret name caught at open, by the config scan");

    // The per-instance check is still the profile resolver's, and still
    // raises its own code when reached directly.
    checkeq(thrown_code([&config] { vs::resolve_profile(config, "default"); }),
            "station_secret_name", "resolve_profile keeps its own check");
  });

  testcase("close-warns-on-typo-plugin-key", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "sdk": { "typo-plugin": { "base": "http://x" } } } } })");
    opts.proxy = "off";
    vs::Station st(opts);
    st.close();
    auto events = st.events();
    bool warned = false;
    for (const auto& ev : events) {
      if (std::string::npos !=
          ev.get("meta").get("warn").str_or("").find("typo-plugin")) {
        warned = true;
      }
    }
    check(warned, "typo'd plugin key warned at close");
    st.close();  // idempotent
  });

  testcase("station-json-loaded-from-disk-upward", [] {
    namespace fs = std::filesystem;
    fs::path root = fs::temp_directory_path() / "vstation-unit";
    fs::remove_all(root);
    fs::create_directories(root / "sub" / "deeper");
    {
      std::ofstream out(root / "station.json");
      out << R"({ "station": 1, "profiles": {
        "default": { "sdk": { "pets": { "base": "http://file:1" } } },
        "prod": { "sdk": { "pets": { "base": "http://file:2" } } } } })";
    }
    checkeq(vs::find_config_file((root / "sub" / "deeper").string()),
            (root / "station.json").string(), "upward walk finds station.json");

    vs::StationOptions opts;
    opts.folder = (root / "sub" / "deeper").string();
    opts.profile = "prod";
    vs::Station st(opts);
    checkeq(st.profile().sdk.get("pets").get("base").str_or(""), "http://file:2",
            "profile overlay from the file wins");
    fs::remove_all(root);
  });

  testcase("legacy-config-warning-event-on-register", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    vs::Station st(opts);
    int client = 0;
    vs::Jval legacy = vs::parse_json(R"({
      "main": { "name": "VoxgigSolardemo" },
      "feature": {}, "options": { "base": "http://x", "auth": {} }, "entity": {} })");
    auto reg = st._register(&client, legacy, vs::Jval::absent());
    checkeq(reg.name, "voxgigsolardemo", "legacy slug");
    bool warned = false;
    for (const auto& ev : st.events()) {
      if (std::string::npos !=
          ev.get("meta").get("warn").str_or("").find("legacy config")) {
        warned = true;
      }
    }
    check(warned, "legacy sentinel warning emitted");
    vs::Jval d = st.descriptor_of("voxgigsolardemo");
    checkeq(d.get("version").str_or(""), "0.0.0", "version sentinel");
    checkeq(d.get("target").str_or(""), "unknown", "target sentinel");
  });

  // --- the Stage 5 later tranche -------------------------------------

  // The shape artifact is DATA and `spec/config-shape.json` is the copy
  // every port reads; this library is vendored into a compiled SDK that
  // cannot see spec/ at run time, so the header carries a MIRROR. THIS
  // IS WHAT KEEPS A MIRROR HONEST - regenerate with `make sync-shape`.
  testcase("config-shape-mirror-matches-spec", [] {
    std::string file = specfile("config-shape.json");
    check(!file.empty(), "spec/config-shape.json found");
    std::ifstream handle(file);
    std::stringstream buffer;
    buffer << handle.rdbuf();
    checkeq(std::string(vs::config_shape_json()), buffer.str(),
            "the embedded mirror is the spec, byte for byte");
  });

  // The shape's own invariants (design 4.3), asserted rather than
  // assumed: a port that reads the artifact should also be able to say
  // what it relies on about it.
  testcase("config-shape-invariants", [] {
    vs::Jval shape = vs::config_shape();
    vs::Jval block = shape.get("profiles").get("`$CHILD`");

    // THE TWO BLOCK SPECS ARE IDENTICAL: an api block and an sdk block
    // are the same grammar at two levels (design 3.1).
    checkeq(vs::canonical_serialize(block.get("api").get("`$CHILD`")),
            vs::canonical_serialize(block.get("sdk").get("`$CHILD`")),
            "api and sdk block specs identical");

    // A FRESH DEEP COPY EVERY CALL: struct's validate consumes the spec
    // it walks, so a second call must not see a half-eaten one.
    check(vs::canonical_serialize(vs::config_shape()) ==
              vs::canonical_serialize(shape),
          "config_shape() is fresh each call");

    // The only `$OPEN` nodes are the three feature-entry nodes - the
    // one place a foreign grammar passes through.
    std::function<int(const vs::Jval&)> countopen = [&countopen](const vs::Jval& v) {
      int n = 0;
      if (v.islist()) {
        for (const auto& item : v.lval) n += countopen(item);
      } else if (v.ismap()) {
        for (const auto& kv : v.mval) {
          if ("`$OPEN`" == kv.first) n++;
          n += countopen(kv.second);
        }
      }
      return n;
    };
    check(3 == countopen(shape), "exactly three `$OPEN` nodes");

    // MERGE_SENSITIVE names the timing rule rather than leaving it to
    // be inferred: it is exactly ['active'], every key in it has a
    // block default, and every block default that is NOT a container is
    // in it.
    const auto& sensitive = vs::merge_sensitive();
    check(1 == sensitive.size() && "active" == sensitive[0],
          "MERGE_SENSITIVE is exactly [active]");
    vs::Jval bdefaults = vs::block_defaults();
    for (const auto& key : sensitive) {
      check(bdefaults.has(key), "merge-sensitive key " + key + " has a default");
    }
    for (const auto& kv : bdefaults.mval) {
      bool container = kv.second.ismap() || kv.second.islist();
      bool named = std::find(sensitive.begin(), sensitive.end(), kv.first) !=
                   sensitive.end();
      check(container || named,
            "non-container block default " + kv.first + " is merge-sensitive");
    }
  });

  // Pure data-in/data-out, and the input is NEVER TOUCHED: the
  // normalized form is an input to validation and to nothing else, so
  // resolve_profile must still see what was written.
  testcase("normalize-config-never-mutates-the-input", [] {
    vs::Jval raw = vs::parse_json(
        R"({ "station": 1, "profiles": { "default": { "sdk": { "solar": {} } } } })");
    std::string before = vs::canonical_serialize(raw);
    vs::Jval normalized = vs::normalize_config(raw);
    checkeq(vs::canonical_serialize(raw), before, "input unchanged");
    check(normalized.get("profiles").get("default").get("sdk").get("solar").has("active"),
          "the copy carries the defaults");

    // A non-map is returned untouched for validate to reject by path.
    checkeq(vs::canonical_serialize(vs::normalize_config(vs::Jval::num(7))), "7",
            "a non-map config passes through");
  });

  // Design 6.1's grammar at the edges the corpus does not spell out.
  testcase("instance-ref-grammar-edges", [] {
    check(vs::check_instance_name("@scope/pkg"), "a scoped name is a name");
    check(!vs::check_instance_name("9nope"), "a name cannot start with a digit");
    check(vs::check_instance_tag("1"), "a tag may start with a digit");
    check(!vs::check_instance_tag("a/b"), "a tag admits no slash");
    check(vs::check_instance_tag(""), "the empty tag is a tag");
    checkeq(vs::check_ref("stripe$"), "stripe", "a trailing $ canonicalizes away");
  });

  // `package` is IN THE GRAMMAR and not honoured here, so the validator
  // stays (it is pure and cheap) and a config shared with a loader port
  // fails the same way in both.
  testcase("check-package-rejects-anything-but-a-module-name", [] {
    checkeq(vs::check_package("x", "@acme/sdk"), "@acme/sdk", "a module name passes");
    for (const auto& bad : {"", "./rel", "/abs", "~/home", "http://x/y",
                            "a\\\\b", "pkg/../../escape", "pkg/./here"}) {
      checkeq(thrown_code([&bad] { vs::check_package("x", bad); }), "station_sdk_load",
              std::string("rejected: ") + bad);
    }
  });

  testcase("factory-provide-is-idempotent-and-conflicts-loudly", [] {
    vs::reset_factories();
    vs::Factory factory;
    factory.config = petconfig();
    factory.construct = petconstruct();

    auto entry = vs::provide("gnarly-pets", factory);
    checkeq(entry->descriptor.get("slug").str_or(""), "gnarly-pets",
            "the descriptor is normalized AT PROVIDE TIME");
    check(entry.get() == vs::provide("gnarly-pets", factory).get(),
          "the same pair twice is a no-op");
    check(vs::factory_for("gnarly-pets").get() == entry.get(), "factory_for finds it");
    check(1 == vs::provided().size() && "gnarly-pets" == vs::provided()[0],
          "provided() lists the slug");

    // A different config IS a different factory, even with the same
    // constructor: a process has one build of an SDK.
    vs::Factory changed;
    changed.construct = factory.construct;
    changed.config = vs::parse_json(R"({ "main": { "name": "Other", "slug": "other" } })");
    checkeq(thrown_code([&changed] { vs::provide("gnarly-pets", changed); }),
            "station_factory_conflict", "a different factory is refused");

    vs::reset_factories();
    check(vs::provided().empty(), "reset_factories clears the table");
  });

  // open() runs validate_config(normalize_config(config)) BEFORE
  // resolving the profile, so a malformed config fails open() with
  // every error at once.
  testcase("open-validates-the-config", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    opts.config = vs::parse_json(
        R"({ "station": 1, "profiles": { "default": { "sdk": {
             "a": { "bass": 1 }, "b": { "tuba": 2 } } } } })");
    std::string message;
    try {
      vs::Station st(opts);
    } catch (const vs::StationError& err) {
      message = err.message();
      checkeq(err.code(), "station_config_invalid", "code");
    }
    check(std::string::npos != message.find("sdk.a: bass") &&
              std::string::npos != message.find("sdk.b: tuba"),
          "every error at once: " + message);
  });

  // READ THE EXPLICIT OPTION FIRST. Inferring before reading it is a
  // real precedence bug that makes repo_scoped=false unsettable for any
  // caller passing a config in code, which is every test of the rule.
  testcase("repo-scoped-reads-the-explicit-option-first", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    vs::Station inferred(opts);
    check(inferred.repo_scoped(), "an in-code config is repo-scoped by construction");

    opts.has_repo_scoped = true;
    opts.repo_scoped = false;
    vs::Station explicitly(opts);
    check(!explicitly.repo_scoped(), "the explicit option wins");
  });

  // `package` stays IN THE GRAMMAR (the corpus validates configs
  // carrying it, and one config file serves a polyglot fleet) and is
  // not honoured here - said out loud, once per api, at open.
  testcase("package-is-not-honoured-and-says-so", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    opts.proxy = "off";
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "api": { "gnarly-pets": { "package": "@acme/gnarly-pets-sdk" } },
      "sdk": { "gnarly-pets": {}, "gnarly-pets$eu": {} } } } })");
    vs::Station st(opts);
    int warned = 0;
    for (const auto& ev : st.events()) {
      if (std::string::npos !=
          ev.get("meta").get("warn").str_or("").find("`package` is not honoured")) {
        warned++;
        checkeq(ev.get("plugin").str_or(""), "gnarly-pets", "the event names the api");
      }
    }
    check(1 == warned, "one warning per api, at open, once");

    // And the error names only the remedies this port actually offers.
    vs::reset_factories();
    std::string message;
    try {
      st.sdk("gnarly-pets");
    } catch (const vs::StationError& err) {
      checkeq(err.code(), "station_no_factory", "code");
      message = err.message();
    }
    check(std::string::npos != message.find("vstation::provide") &&
              std::string::npos == message.find("api.gnarly-pets.package"),
          "the remedy is provide, not package: " + message);
  });

  testcase("declarative-sdk-create-and-instances", [] {
    vs::reset_factories();
    vs::Factory factory;
    factory.config = petconfig();
    factory.construct = petconstruct();
    vs::provide("gnarly-pets", factory);

    vs::StationOptions opts;
    opts.has_config = true;
    opts.proxy = "off";
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "sdk": {
        "gnarly-pets": { "base": "http://a", "options": { "timeout": 5 } },
        "gnarly-pets$eu": { "base": "http://b", "secret": "gnarly_pets_eu.apikey" },
        "gnarly-pets$off": { "active": false, "secret": "gnarly_pets_off.apikey" } }
      } } })");
    vs::Station st(opts);

    auto first = st.sdk("gnarly-pets");
    check(first.get() == st.sdk("gnarly-pets").get(), "sdk() caches by name");
    vs::Jval built = *std::static_pointer_cast<vs::Jval>(first);
    checkeq(built.get("base").str_or(""), "http://a", "the block's base reaches options");
    checkeq(vs::canonical_serialize(built.get("timeout")), "5",
            "the block's options reach options");
    checkeq(built.get("feature").get("station").get("instance").str_or(""),
            "gnarly-pets", "the instance name rides the feature options");
    check(built.get("feature").get("station").get("active").bval,
          "station's own entry is composed last and always wins");

    // create() is UNCACHED and takes the lowest free integer tag, so an
    // auto-tagged client is an ORDINARY instance rather than a parallel
    // identity scheme.
    auto extra = st.create("gnarly-pets");
    check(extra.get() != first.get(), "create() is uncached");
    checkeq(st.autotag("gnarly-pets"), "gnarly-pets$1",
            "autotag is the lowest free integer tag");

    checkeq(thrown_code([&st] { st.sdk("gnarly-pets$off"); }),
            "station_instance_inactive", "an inactive instance is barred");
    checkeq(thrown_code([&st] { st.sdk("gnarly-pets$nope"); }), "station_no_instance",
            "an undeclared instance is refused by name");

    auto rows = st.instances();
    check(3 == rows.size(), "one row per DECLARED instance");
    checkeq(rows[0].name, "gnarly-pets", "sorted by name");
    checkeq(rows[1].name, "gnarly-pets$eu", "sorted by name");
    check(!rows[2].active, "gnarly-pets$off is declared and barred");
    check(!rows[1].live, "a declared instance is not live until built");
    vs::reset_factories();
  });

  // Provenance is the half that makes a fleet view usable rather than
  // merely correct - at 26 instances "why is retry off here" is the
  // question, and a merged map alone cannot answer it.
  testcase("features-of-provenance-order-and-policy-budget", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    opts.proxy = "off";
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": {
      "default": {
        "feature": { "retry": { "max": 1, "wait": 100 } },
        "api": { "gnarly-pets": { "feature": { "retry": { "max": 2 } } } },
        "sdk": { "gnarly-pets$eu": {
          "feature": { "retry": { "max": 3 } },
          "policy": { "budget": { "rps": 5, "concurrency": 2 } } } } },
      "prod": { "feature": { "debug": { "level": 1 } } } } })");
    opts.profile = "prod";
    vs::Station st(opts);

    auto set = st.features_of("gnarly-pets$eu");
    checkeq(vs::canonical_serialize(set.merged.get("retry")),
            "{\"max\":3,\"wait\":100}", "three-level merge, per option key");
    checkeq(set.from.get("retry").get("max").str_or(""), "default.sdk",
            "provenance names the level that wrote it");
    checkeq(set.from.get("retry").get("wait").str_or(""), "default.feature",
            "and the level that wrote the key beside it");
    checkeq(set.from.get("debug").get("level").str_or(""), "prod.feature",
            "profile specificity outranks block specificity");

    // The budget composes INTO the merged map, so every consumer sees
    // it: build() orders it, check() validates it, the view reports it.
    checkeq(vs::canonical_serialize(set.merged.get("ratelimit")),
            "{\"active\":true,\"burst\":2,\"rate\":5}",
            "policy.budget composes into ratelimit");
    checkeq(set.from.get("ratelimit").get("rate").str_or(""), "policy.budget",
            "and says policy set it");

    // THE IMPLICIT STATION ENTRY IS FOR ORDERING ONLY: it is in the
    // reported order and never in `merged`.
    check(!set.merged.has("station"), "station is never in merged");
    check(!set.ordered.empty() && "station" == set.ordered.back(),
          "station is pinned innermost");

    // The fleet view narrows to the question asked.
    vs::Station::FeatureFilter only;
    only.feature = "ratelimit";
    auto rows = st.features(only);
    check(1 == rows.size(), "only the instance carrying it");
    checkeq(rows[0].instance, "gnarly-pets$eu", "the row names the instance");
    check(1 == rows[0].ordered.size() && "ratelimit" == rows[0].ordered[0],
          "the row is narrowed to the feature asked about");
  });

  // The schema arrives with the FACTORY, not with a live client, so a
  // feature typo is a CI failure rather than a setting that quietly did
  // nothing in production.
  testcase("check-catches-a-feature-typo-without-constructing", [] {
    vs::reset_factories();
    vs::Factory factory;
    factory.config = petconfig();
    factory.construct = petconstruct();
    vs::provide("gnarly-pets", factory);

    vs::StationOptions opts;
    opts.has_config = true;
    opts.proxy = "off";
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "sdk": { "gnarly-pets": { "feature": { "nope": { "on": true } } },
               "gnarly-pets$ok": {} } } } })");
    vs::Station st(opts);

    auto result = st.check();
    check(1 == result.ok.size() && "gnarly-pets$ok" == result.ok[0],
          "the sound instance constructs");
    check(1 == result.failed.size(), "the typo'd one is reported, not thrown");
    checkeq(result.failed[0].name, "gnarly-pets", "named");
    checkeq(result.failed[0].code, "station_feature_unknown", "code");
    check(std::string::npos != result.failed[0].message.find("it declares [test]"),
          "the message names what the SDK does declare");

    // And the SAME check fires on the production path, because every
    // path to a constructor comes through build().
    checkeq(thrown_code([&st] { st.sdk("gnarly-pets"); }), "station_feature_unknown",
            "sdk() does not silently ignore it");
    vs::reset_factories();
  });

  // THE REGISTRY IS THE AUTHORITY: a name nobody declared or registered
  // is a MISS, not a lookup - a wider fallback would let a typo derive a
  // secret name, call the provider, and report a nonexistent instance
  // warmed off a shared api-level credential.
  testcase("warm-is-registry-or-declaration-and-nothing-else", [] {
    setenv("GNARLY_PETS_APIKEY", "sk-warm", 1);
    vs::StationOptions opts;
    opts.has_config = true;
    opts.proxy = "off";
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "sdk": { "gnarly-pets": {},
               "gnarly-pets$off": { "active": false,
                                    "secret": "gnarly_pets_off.apikey" } } } } })");
    vs::Station st(opts);

    auto all = st.warm();
    check(1 == all.warmed.size() && "gnarly-pets" == all.warmed[0],
          "with no names, the ACTIVE declared instances only");
    check(all.missed.empty(), "and nothing missed");

    auto named = st.warm({"gnarly-pets", "gnarly-pets$off", "gnarly-pets$prodd"});
    check(1 == named.warmed.size(), "an explicit name includes the inactive one");
    check(2 == named.missed.size() && "gnarly-pets$off" == named.missed[0] &&
              "gnarly-pets$prodd" == named.missed[1],
          "an undeclared name is a miss, never a lookup");
    unsetenv("GNARLY_PETS_APIKEY");
  });

  std::cout << "\n" << PASSCOUNT << " passed, " << FAILCOUNT << " failed\n";
  return 0 == FAILCOUNT ? 0 : 1;
}
