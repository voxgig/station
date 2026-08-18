// RUN: make test          (or: ./build/conform [sectionname])
//
// The station conformance suite: the pure-contract half of the design's
// (station.md 13) corpus, from spec/station.json, through voxgig/omni -
// the same file every port runs. Sections that need live SDK machinery
// (inject, order, event correlation) live in generated-SDK runs; the
// corpus carries what a port can prove with no SDK present.
//
// No third-party test framework: a failing omni check throws OmniError,
// printed here and reflected in the exit code (omni's own C++ harness
// pattern). omni is a sibling checkout, not a published package: point
// the Makefile's OMNI at it (or keep the default sibling path).

#include <filesystem>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

#include "omni.hpp"

#include "../src/voxgig_station.hpp"

namespace {

std::string ONLY;
int PASSCOUNT = 0;
int FAILCOUNT = 0;

namespace vs = vstation;

// The station spec, wherever this port is running from (cpp/ or the
// repo root).
std::string specfile() {
  std::filesystem::path dir = std::filesystem::current_path();
  for (int step = 0; step < 8; step++) {
    std::filesystem::path cand = dir / "spec" / "station.json";
    if (std::filesystem::exists(cand)) {
      return cand.string();
    }
    if (!dir.has_parent_path() || dir == dir.parent_path()) {
      break;
    }
    dir = dir.parent_path();
  }
  throw omni::OmniError("station: spec/station.json not found");
}

// ---------------------------------------------------------------------
// Bridges between omni's value model and the library's Jval. Spec nulls
// arrive as omni's NULLMARK sentinel (default runset flags); restore
// them so a subject sees what the spec means - kept as real nulls for
// `canonical`, dropped (absent) for config-shaped inputs, exactly as
// the ts/lua conform tests denull.
// ---------------------------------------------------------------------

vs::Jval to_station(const omni::Json& val, bool keepnull) {
  if (val.isnone() || (val.isstr() && omni::NULLMARK == val.strval)) {
    return keepnull ? vs::Jval::null() : vs::Jval::absent();
  }
  if (val.isbool()) {
    return vs::Jval::boolean(val.boolval);
  }
  if (val.isnum()) {
    return vs::Jval::num(val.numval);
  }
  if (val.isstr()) {
    return vs::Jval::str(val.strval);
  }
  if (val.islist()) {
    vs::Jval out = vs::Jval::list();
    for (const auto& entry : val.listval) {
      vs::Jval conv = to_station(entry, keepnull);
      out.push(conv.isabsent() ? vs::Jval::null() : conv);
    }
    return out;
  }
  if (val.ismap()) {
    vs::Jval out = vs::Jval::map();
    for (const auto& entry : val.mapval) {
      vs::Jval conv = to_station(entry.second, keepnull);
      if (!conv.isabsent()) {
        out.set(entry.first, conv);
      }
    }
    return out;
  }
  return vs::Jval::absent();
}

omni::Json to_omni(const vs::Jval& val) {
  switch (val.type) {
    case vs::Jval::Type::Absent:
      return omni::Json::absent();
    case vs::Jval::Type::Null:
      return omni::Json::null();
    case vs::Jval::Type::Bool:
      return omni::Json::boolean(val.bval);
    case vs::Jval::Type::Num:
      return omni::Json::num(val.nval);
    case vs::Jval::Type::Str:
      return omni::Json::str(val.sval);
    case vs::Jval::Type::List: {
      omni::Json out = omni::Json::list();
      for (const auto& entry : val.lval) {
        out.push(to_omni(entry));
      }
      return out;
    }
    case vs::Jval::Type::Map: {
      omni::Json out = omni::Json::map();
      for (const auto& entry : val.mval) {
        omni::Json conv = to_omni(entry.second);
        if (!conv.isabsent()) {
          out.set(entry.first, conv);
        }
      }
      return out;
    }
  }
  return omni::Json::absent();
}

void testcase(const std::string& name, const std::function<void()>& body) {
  if (!ONLY.empty() && name != ONLY) {
    return;
  }
  try {
    body();
    PASSCOUNT++;
    std::cout << "ok   - " << name << "\n";
  } catch (const std::exception& err) {
    FAILCOUNT++;
    std::cout << "FAIL - " << name << "\n" << err.what() << "\n";
  }
}

// ---------------------------------------------------------------------
// Subjects
// ---------------------------------------------------------------------

const omni::Subject SECRETNAME = [](const std::vector<omni::Json>& args) {
  std::string slug = args[0].get("slug").strval;
  std::string secretname = vs::secretname_default(slug);
  omni::Json out = omni::Json::map();
  out.set("envtoken", omni::Json::str(vs::envtoken(slug)));
  out.set("secretname", omni::Json::str(secretname));
  out.set("envkey", omni::Json::str(vs::envkey(secretname)));
  return out;
};

const omni::Subject PLACEHOLDER = [](const std::vector<omni::Json>& args) {
  return omni::Json::str(vs::placeholder_for(args[0].strval));
};

const omni::Subject DESCRIPTOR = [](const std::vector<omni::Json>& args) {
  vs::Jval config = to_station(args[0].get("config"), false);
  vs::Jval feature = to_station(args[0].get("feature"), false);
  return to_omni(vs::normalize_descriptor(config, feature).descriptor);
};

const omni::Subject DESCRIPTORWARNINGS = [](const std::vector<omni::Json>& args) {
  vs::Jval config = to_station(args[0].get("config"), false);
  vs::Jval feature = to_station(args[0].get("feature"), false);
  return omni::Json::num(static_cast<double>(
      vs::normalize_descriptor(config, feature).warnings.size()));
};

const omni::Subject CANONICAL = [](const std::vector<omni::Json>& args) {
  // NULLMARK sentinels come back as real nulls: the serializer must see
  // what the spec means.
  return omni::Json::str(vs::canonical_serialize(to_station(args[0], true)));
};

const omni::Subject PROFILE = [](const std::vector<omni::Json>& args) {
  vs::Jval config = to_station(args[0].get("config"), false);
  std::string profile = args[0].get("profile").strval;
  vs::ResolvedProfile resolved = vs::resolve_profile(config, profile);
  omni::Json out = omni::Json::map();
  out.set("name", omni::Json::str(resolved.name));
  out.set("plugin", to_omni(resolved.plugin));
  out.set("providers", to_omni(resolved.providers));
  return out;
};

const omni::Subject ERRORS = [](const std::vector<omni::Json>& args) {
  return omni::Json::boolean(vs::known_code(args[0].strval));
};

}  // namespace

int main(int argc, char** argv) {
  if (1 < argc) {
    ONLY = argv[1];
  }

  omni::RunPack R = omni::makeRunner(specfile()).runner("station");

  testcase("secretname", [&R] { R.runset(R.set("secretname"), SECRETNAME); });
  testcase("placeholder", [&R] { R.runset(R.set("placeholder"), PLACEHOLDER); });
  testcase("descriptor", [&R] { R.runset(R.set("descriptor"), DESCRIPTOR); });
  testcase("descriptorwarnings",
           [&R] { R.runset(R.set("descriptorwarnings"), DESCRIPTORWARNINGS); });
  testcase("canonical", [&R] { R.runset(R.set("canonical"), CANONICAL); });
  testcase("profile", [&R] { R.runset(R.set("profile"), PROFILE); });
  testcase("errors", [&R] { R.runset(R.set("errors"), ERRORS); });

  std::cout << "\n" << PASSCOUNT << " passed, " << FAILCOUNT << " failed\n";
  return 0 == FAILCOUNT ? 0 : 1;
}
