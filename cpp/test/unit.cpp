// RUN: make test          (or: ./build/unit [testname])
//
// Focused unit tests for the parts of the C++ station library the
// conformance corpus cannot reach standalone: the event ring, the
// env-only secret broker, the ambient instance contract, registration,
// and profile-file loading. The SDK seam (feature_binding, transport
// middleware, injection) is exercised inside generated SDKs.

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
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

    auto reg = st._register(&client, petconfig(), vs::Jval::absent(), "");
    checkeq(reg.slug, "gnarly-pets", "slug");
    checkeq(reg.rung, "R1", "rung");
    checkeq(reg.placeholder, "[station:gnarly-pets]", "placeholder");
    checkeq(reg.secretname, "gnarly_pets.apikey", "secretname default");
    check(st._bound(&client), "client bound");

    int client2 = 0;
    checkeq(thrown_code([&] { st._register(&client2, petconfig(), vs::Jval::absent(), ""); }),
            "station_bound_twice", "duplicate slug refused");

    std::string canonical = st.canonical_descriptor("gnarly-pets");
    check(0 == canonical.rfind("{\"auth\":", 0), "canonical keys sorted");
    check(std::string::npos != canonical.find("\"envtoken\":\"GNARLY_PETS\""),
          "canonical carries envtoken");

    checkeq(thrown_code([&st] { st.descriptor_of("nope"); }), "station_no_plugin",
            "unknown plugin code");
  });

  testcase("register-secret-name-precedence", [] {
    vs::StationOptions o1;
    o1.has_config = true;
    o1.config = vs::parse_json(
        R"({ "station": 1, "profiles": { "default": {
             "sdk": { "gnarly-pets": { "secret": "profile.name" } } } } })");
    vs::Station st(o1);
    int c1 = 0;
    auto reg1 = st._register(&c1, petconfig(), vs::Jval::absent(), "code.name");
    checkeq(reg1.secretname, "code.name", "feature option beats profile");

    vs::Station st2(o1);
    int c2 = 0;
    auto reg2 = st2._register(&c2, petconfig(), vs::Jval::absent(), "");
    checkeq(reg2.secretname, "profile.name", "profile beats descriptor default");
  });

  testcase("profile-bad-secret-name-at-load", [] {
    vs::StationOptions opts;
    opts.has_config = true;
    opts.config = vs::parse_json(R"({ "station": 1, "profiles": { "default": {
      "sdk": { "a": { "secret": "Not A Name" } } } } })");
    checkeq(thrown_code([&opts] { vs::Station st(opts); }), "station_secret_name",
            "malformed secret name caught at profile load");
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
    auto reg = st._register(&client, legacy, vs::Jval::absent(), "");
    checkeq(reg.slug, "voxgigsolardemo", "legacy slug");
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

  std::cout << "\n" << PASSCOUNT << " passed, " << FAILCOUNT << " failed\n";
  return 0 == FAILCOUNT ? 0 : 1;
}
