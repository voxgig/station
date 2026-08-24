// RUN: make test          (or: ./build/conform [sectionname])
//
// The station conformance suite: the pure-contract half of the design's
// (station.md 13) corpus, from spec/station.json, through voxgig/omni -
// the same file every port runs. Sections that need live SDK machinery
// (inject, event correlation) live in generated-SDK runs; the corpus
// carries what a port can prove with no SDK present.
//
// TEN SECTIONS, ONE PENDING. The tests are REGISTERED FROM THE `DRIVERS`
// TABLE below rather than written out by hand, so a section named there
// cannot silently fail to run; `sections-covered` closes the other
// direction by reading spec/station.json AS RAW JSON - not through the
// runner, which resolves a named section and would hide one it never
// resolved - and asserting that the sections it carries are exactly
// DRIVERS plus PENDING. A section added to the corpus and not picked up
// here fails loudly instead of never running; a section renamed or
// deleted while this port still lists it fails too.
//
// C++ has no dynamic test registry, so the two tables are static arrays
// iterated by main() - the same two properties the dynamic ports get
// from generating their tests.
//
// No third-party test framework: a failing omni check throws OmniError,
// printed here and reflected in the exit code (omni's own C++ harness
// pattern). omni is a sibling checkout, not a published package: point
// the Makefile's OMNI at it (or keep the default sibling path).

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
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

// The 3.3 merge, and the whole of this port's profile contract (the
// pre-rename `profile` section is PENDING below, not run).
const omni::Subject INSTANCE = [](const std::vector<omni::Json>& args) {
  vs::Jval config = to_station(args[0].get("config"), false);
  std::string profile = args[0].get("profile").strval;
  vs::ResolvedProfile resolved = vs::resolve_profile(config, profile);
  omni::Json out = omni::Json::map();
  out.set("name", omni::Json::str(resolved.name));
  out.set("api", to_omni(resolved.api));
  out.set("sdk", to_omni(resolved.sdk));
  out.set("providers", to_omni(resolved.providers));
  return out;
};

const omni::Subject ERRORS = [](const std::vector<omni::Json>& args) {
  return omni::Json::boolean(vs::known_code(args[0].strval));
};

// Design 4.2's pipeline, and the whole of this port's config contract:
// the entry is a RAW config in, and either the normalized output or the
// expected error out. THE TWO STEPS ARE ONE PIPELINE - a port that split
// them would be free to validate the wrong form, which is the exact
// mistake 4.2 exists to prevent (an all-optional block is an OPEN map
// until normalization makes its keys present).
const omni::Subject CONFIG = [](const std::vector<omni::Json>& args) {
  vs::Jval raw = to_station(args[0], false);
  return to_omni(vs::validate_config(vs::normalize_config(raw)));
};

// Design 6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
// rather than driver-shaped even though it decides a registry key.
const omni::Subject INSTANCEREF = [](const std::vector<omni::Json>& args) {
  std::string api = args[0].get("api").strval;
  vs::Jval opts = to_station(args[0].get("opts"), false);
  return omni::Json::str(vs::instance_ref(api, opts));
};

// Design 8's pure half (design 10.1): the three-level merge with its
// depth boundary, and the 8.4 order resolution. ONE DRIVER, TWO ENTRY
// SHAPES - `merged` selects the resolver, anything else the merge -
// because a port that guessed from looser cues would run the wrong
// subject on a mistyped entry.
const omni::Subject FEATURE = [](const std::vector<omni::Json>& args) {
  if (args[0].has("merged")) {
    vs::Jval merged = to_station(args[0].get("merged"), false);
    std::vector<vs::Ordered> ordered = vs::resolve_order(merged);
    vs::check_pin(ordered);
    omni::Json names = omni::Json::list();
    for (const auto& row : ordered) {
      names.push(omni::Json::str(row.name));
    }
    return names;
  }

  vs::Jval base = to_station(args[0].get("base"), false);
  vs::Jval overlay = to_station(args[0].get("overlay"), false);
  std::string api = args[0].get("api").strval;
  std::string ref = args[0].get("ref").strval;
  return to_omni(vs::merge_features(vs::feature_sources(base, overlay, api, ref)));
};

// ---------------------------------------------------------------------
// The two tables: what runs, and what deliberately does not.
//
// DRIVERS is the opt-in surface: a section runs if and only if it has a
// row here, and the runs below are generated from it. PENDING is a
// recorded DECISION not to run one, with the reason in the row - an
// entry here is visible in review, where a section quietly dropped from
// DRIVERS to make a red test go away is not. `sections-covered` then
// asserts the two together are exactly what the corpus carries.
// ---------------------------------------------------------------------

struct DriverRow {
  const char* name;
  const omni::Subject* subject;
};

const DriverRow DRIVERS[] = {
    {"secretname", &SECRETNAME},
    {"placeholder", &PLACEHOLDER},
    {"descriptor", &DESCRIPTOR},
    {"descriptorwarnings", &DESCRIPTORWARNINGS},
    {"canonical", &CANONICAL},
    {"config", &CONFIG},
    {"instance", &INSTANCE},
    {"instanceref", &INSTANCEREF},
    {"feature", &FEATURE},
    {"errors", &ERRORS},
};

struct PendingRow {
  const char* name;
  const char* reason;
};

const PendingRow PENDING[] = {
    // Pins the pre-Stage-1 `plugin` grammar, which this port no longer
    // speaks. It stays in the corpus for the ports that have not crossed
    // the rename yet and is deleted when the last one does - see
    // spec/README.md. Everything it pins is restated in the sdk/api
    // grammar the `instance` section runs.
    {"profile", "pre-rename plugin grammar; superseded by the instance section"},
};

// Section completeness (design station.md 13). Reads spec/station.json
// AS RAW JSON - not through the runner, which resolves and normalizes a
// named section and would hide one it never resolved - and asserts that
// the section names it carries are EXACTLY the DRIVERS rows plus the
// PENDING rows. Not a subset either way: a section added to the corpus
// and not picked up here fails loudly instead of never running, and a
// stale driver or a stale pending pin fails rather than rotting.
void sections_covered(const std::string& path) {
  std::ifstream handle(path);
  std::stringstream buffer;
  buffer << handle.rdbuf();
  vs::Jval spec = vs::parse_json(buffer.str());

  std::vector<std::string> present =
      vs::sorted_keys_of(spec.get("primary").get("station"));

  std::vector<std::string> covered;
  for (const auto& row : DRIVERS) {
    covered.push_back(row.name);
  }
  for (const auto& row : PENDING) {
    covered.push_back(row.name);
  }
  std::sort(covered.begin(), covered.end());

  if (present != covered) {
    throw omni::OmniError("  corpus:  " + vs::join_strings(present, ", ") +
                          "\n  covered: " + vs::join_strings(covered, ", "));
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (1 < argc) {
    ONLY = argv[1];
  }

  std::string path = specfile();
  omni::RunPack R = omni::makeRunner(path).runner("station");

  testcase("sections-covered", [&path] { sections_covered(path); });

  // REGISTERED FROM THE TABLE, never written out by hand: a section
  // named in DRIVERS cannot silently fail to execute.
  for (const auto& row : DRIVERS) {
    testcase(row.name, [&R, &row] {
      omni::Json set = R.set(row.name);
      // The corpus must actually carry a set of this name - a renamed
      // section quietly matching nothing is the failure mode a
      // table-driven suite would otherwise hide.
      if (set.isnone()) {
        throw omni::OmniError("corpus section missing: " + std::string(row.name));
      }
      R.runset(set, *row.subject);
    });
  }

  std::cout << "\n" << PASSCOUNT << " passed, " << FAILCOUNT << " failed\n";
  return 0 == FAILCOUNT ? 0 : 1;
}
