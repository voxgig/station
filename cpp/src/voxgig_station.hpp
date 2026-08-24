// voxgig/station - C++ port (header-only, C++17, standard library only).
//
// A port of the canonical TypeScript implementation (typescript/src/);
// behaviour must match, case for case, through the shared conformance
// corpus (spec/station.json, run via voxgig/omni).
//
// TIER C SCOPE (design station.md 2.2, 10.1): solo mode only - no wire
// client, no proxy attachment. `proxy: "require"` therefore fails on the
// operation path with station_no_proxy (design 2.1/14), and `auto`
// degrades to solo with one warning event.
//
// ENV-ONLY SECRETS, AND IT SAYS SO (design station.md 2.2): there is no
// sekreto C++ port, so this library resolves secrets from the process
// environment only, read directly under the envkey of the secret name -
// `taskpad.apikey` -> `TASKPAD_APIKEY`, the same mapping sekreto's
// envkey() defines and the env var generated SDKs already document. A
// profile whose provider chain names any other store gets a warning
// event at open() (and status().secrets == "env-only"), never a silent
// partial implementation. The permanent fix is a sekreto C++ port,
// contributed to sekreto; this library must not grow a provider chain.
//
// ONE HEADER, TWO HALVES. The first half is the self-contained core
// (identity rules, canonical serializer, descriptor normalizer, profile
// resolution, event ring, env-only secret broker, the Station hub); it
// compiles anywhere and is what the conformance corpus exercises. The
// second half - guarded by `#if defined(SDK_CORE_TYPES_HPP)`, the
// include guard of a generated C++ SDK's core/types.hpp - is the
// SDK-facing seam (options(), feature_binding(), the transport
// middleware) and compiles only inside a generated SDK, where
// sdk::Value and the pipeline types exist. Within one program the
// header is always included the same way (every SDK test TU includes
// the whole SDK first), so the two shapes never mix.
//
// DESIGN DELTA, recorded (station design 3.1 lists inverted binding for
// static languages): the C++ SDK target deliberately does not wire
// `options.extend` (no extend-list-in-Value), so connect()/adopt() do
// not exist here and regeneration with the station feature is the only
// retrofit. Binding is st->options() (inverted) or a hand-written
// feature.station.active entry; the generated StationFeature binds to
// the AMBIENT station only - a C++ options map cannot carry an instance
// handle through the generated clone/merge/validate pipeline.
//
// VENDORED: generated C++ SDKs receive this file vendored at
// feature/station/voxgig_station.hpp via the sdkgen-station package
// (no C++ package registry exists to declare a dependency in). The copy
// here is canonical - edit here first, then refresh the vendored copy
// byte-identically.

#ifndef VOXGIG_STATION_HPP
#define VOXGIG_STATION_HPP

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// THE SECOND RUNTIME DEPENDENCY (design station.md 4, 9). Config
// validation is voxgig/struct's - `validate` with an `errs` collection
// so it COLLECTS rather than throwing at the first problem, closed maps
// by default, and `$OPEN` where a foreign grammar passes through - and
// not a second validator written here. It runs at open(), not only
// under test, so it is a runtime dependency and not a test one.
//
// C++ has no package registry, so struct is VENDORED exactly as this
// library is: a generated C++ SDK already carries it (the SDK's own
// `utility/voxgigstruct/`, the precedent VENDORED.md names) beside this
// library's `feature/station/`. In THIS checkout the Makefile puts the
// sibling voxgig/struct's `cpp/src` on the include path, found the way
// every port finds its siblings ($STRUCT_HOME, then a sibling
// directory, then two fixed fallbacks). Both headers are header-only,
// so there is nothing to link.
//
// Included with -isystem here for the same reason the C port compiles
// struct with struct's own flags: -Werror over somebody else's warnings
// is a build that breaks on their next release.
#include "voxgig_struct.hpp"
#include "value_io.hpp"

namespace vstation {

inline const char* VERSION = "0.0.1";

// ---------------------------------------------------------------------
// Jval - the library's own small JSON value. The station core must
// compile with no SDK present (the corpus runs it standalone), so it
// cannot use the generated SDK's Value; the SDK seam converts at the
// boundary (to_jval, below the guard). Maps preserve insertion order;
// the canonical serializer sorts keys itself (design station.md 4).
// Absent and null are distinct by construction, mirroring ts
// undefined-vs-null: absent map values are dropped by the serializer,
// null is emitted as JSON null.
// ---------------------------------------------------------------------

class Jval {
 public:
  enum class Type { Absent, Null, Bool, Num, Str, List, Map };

  Type type = Type::Absent;
  bool bval = false;
  double nval = 0.0;
  std::string sval;
  std::vector<Jval> lval;
  std::vector<std::pair<std::string, Jval>> mval;

  Jval() = default;

  static Jval absent() { return Jval(); }

  static Jval null() {
    Jval out;
    out.type = Type::Null;
    return out;
  }

  static Jval boolean(bool v) {
    Jval out;
    out.type = Type::Bool;
    out.bval = v;
    return out;
  }

  static Jval num(double v) {
    Jval out;
    out.type = Type::Num;
    out.nval = v;
    return out;
  }

  static Jval str(const std::string& v) {
    Jval out;
    out.type = Type::Str;
    out.sval = v;
    return out;
  }

  static Jval list() {
    Jval out;
    out.type = Type::List;
    return out;
  }

  static Jval map() {
    Jval out;
    out.type = Type::Map;
    return out;
  }

  bool isabsent() const { return Type::Absent == type; }
  bool isnull() const { return Type::Null == type; }
  bool isnone() const { return isabsent() || isnull(); }
  bool isbool() const { return Type::Bool == type; }
  bool isnum() const { return Type::Num == type; }
  bool isstr() const { return Type::Str == type; }
  bool islist() const { return Type::List == type; }
  bool ismap() const { return Type::Map == type; }

  // Read a map entry; absent when missing (or when this is not a map).
  Jval get(const std::string& key) const {
    if (ismap()) {
      for (const auto& entry : mval) {
        if (entry.first == key) {
          return entry.second;
        }
      }
    }
    return Jval::absent();
  }

  bool has(const std::string& key) const {
    if (!ismap()) {
      return false;
    }
    for (const auto& entry : mval) {
      if (entry.first == key) {
        return true;
      }
    }
    return false;
  }

  void set(const std::string& key, const Jval& v) {
    if (Type::Map != type) {
      type = Type::Map;
      bval = false;
      nval = 0.0;
      sval.clear();
      lval.clear();
      mval.clear();
    }
    for (auto& entry : mval) {
      if (entry.first == key) {
        entry.second = v;
        return;
      }
    }
    mval.emplace_back(key, v);
  }

  void push(const Jval& v) {
    if (Type::List != type) {
      type = Type::List;
      bval = false;
      nval = 0.0;
      sval.clear();
      lval.clear();
      mval.clear();
    }
    lval.push_back(v);
  }

  // The string value, or a default for anything else.
  std::string str_or(const std::string& deflt = "") const {
    return isstr() ? sval : deflt;
  }
};

// A truthy non-empty string, or the next candidate (ts `a || b || ''`).
inline std::string first_truthy_str(const Jval& a, const Jval& b,
                                    const std::string& deflt = "") {
  if (a.isstr() && !a.sval.empty()) return a.sval;
  if (b.isstr() && !b.sval.empty()) return b.sval;
  return deflt;
}

// ---------------------------------------------------------------------
// Errors (design station.md 14): <subject>_<condition> house grammar,
// exact strings pinned by the `errors` corpus section.
// ---------------------------------------------------------------------

inline const std::vector<std::string>& known_codes() {
  static const std::vector<std::string> CODES = {
      "station_no_proxy",
      "station_secret_no_value",
      "station_secret_error",
      "station_secret_name",
      "station_host_allow",
      "station_grant_expired",
      "station_wrap_order",
      "station_protocol",
      "station_no_plugin",
      "station_no_entity",
      "station_no_op",
      "station_agent_allow",
      "station_body_limit",
      "station_replay_lossy",
      "station_open_conflict",
      "station_bound_twice",

      // Declarative config (design §6.4). Only the reference ports raise
      // the config-validation codes so far (Stage 1); the catalog is
      // repo-wide, so every port knows them.
      "station_config_invalid",
      "station_config_secret",
      "station_secret_collision",
      "station_feature_reserved",

      // Instances (design §6.4). `as` is a tag, not a free name.
      "station_instance_api",

      // The declarative front door (design §6.4). Availability errors
      // are fatal at first use, not at open().
      "station_no_instance",
      "station_instance_inactive",
      "station_sdk_load",
      "station_no_factory",
      "station_factory_conflict",

      // Features (design §8.4, §8.5).
      "station_feature_unknown",
      "station_feature_option",
      "station_feature_order",
  };
  return CODES;
}

inline bool known_code(const std::string& code) {
  const auto& codes = known_codes();
  return std::find(codes.begin(), codes.end(), code) != codes.end();
}

class StationError : public std::runtime_error {
 public:
  StationError(const std::string& code, const std::string& message)
      : std::runtime_error(code + ": " + message), code_(code), message_(message) {}

  const std::string& code() const { return code_; }
  const std::string& message() const { return message_; }

 private:
  std::string code_;
  std::string message_;
};

// ---------------------------------------------------------------------
// Identity: envtoken / secret names (design station.md 5.1)
// ---------------------------------------------------------------------

// The ONLY way to build an env-var token in station, mirroring sdkgen's
// packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
// `secretname` corpus section pins the round-trip against sekreto's
// envkey() and sdkgen's envName() - the one place three grammars meet.
inline std::string envtoken(const std::string& name) {
  std::string out;
  bool gap = false;
  for (unsigned char c : name) {
    if (std::isalnum(c)) {
      if (gap && !out.empty()) {
        out.push_back('_');
      }
      gap = false;
      out.push_back(static_cast<char>(std::toupper(c)));
    } else {
      gap = true;
    }
  }
  return out;
}

// The default sekreto name for a plugin (design station.md 5.1):
// envtoken(slug) lowercased, plus '.apikey'. envkey() then yields
// exactly the env var the SDK's README documents:
// gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
inline std::string secretname_default(const std::string& slug) {
  std::string out = envtoken(slug);
  std::transform(out.begin(), out.end(), out.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return out + ".apikey";
}

// Best-effort slug from a camel name, for SDKs whose embedded config
// predates main.slug (design station.md 4 legacy sentinels). The hyphen
// caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
// 'voxgig-solardemo' - callers surface a warning event when this path
// is taken.
inline std::string legacy_slug(const std::string& name) {
  std::string out = name;
  std::transform(out.begin(), out.end(), out.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return out;
}

// Is this a well-formed secret name? sekreto's grammar: dot-separated
// segments of [a-z0-9_]+ (restated here because there is no sekreto C++
// port to include it from; the grammar is sekreto's, pinned by its spec).
inline bool validname(const std::string& name) {
  if (name.empty()) {
    return false;
  }
  size_t start = 0;
  for (;;) {
    size_t dot = name.find('.', start);
    size_t end = (std::string::npos == dot) ? name.size() : dot;
    if (end == start) {
      return false;
    }
    for (size_t i = start; i < end; i++) {
      unsigned char c = static_cast<unsigned char>(name[i]);
      bool ok = ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || '_' == c;
      if (!ok) {
        return false;
      }
    }
    if (std::string::npos == dot) {
      return true;
    }
    start = dot + 1;
    if (start >= name.size()) {
      return false;
    }
  }
}

// The environment-variable key for a name: api.token -> API_TOKEN
// (sekreto's envkey mapping - the one store mapping an env-only library
// legitimately carries, because it is the mapping it reads by).
inline std::string envkey(const std::string& name) {
  if (!validname(name)) {
    throw StationError("station_secret_error", "invalid secret name: " + name);
  }
  std::string out = name;
  for (auto& c : out) {
    if ('.' == c) {
      c = '_';
    } else {
      c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
  }
  return out;
}

// ---------------------------------------------------------------------
// JSON: canonical serializer + a small strict parser
// ---------------------------------------------------------------------

inline std::string escape_json_string(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  return out;
}

// JSON.stringify semantics for a double: integral within the exact range
// prints as an integer token; non-finite is null; anything else the
// shortest round-trip decimal.
inline std::string serialize_number(double v) {
  if (!std::isfinite(v)) {
    return "null";
  }
  if (v == std::floor(v) && std::fabs(v) < 9007199254740992.0) {
    return std::to_string(static_cast<long long>(v));
  }
  char buf[40];
  for (int prec = 15; prec <= 17; prec++) {
    std::snprintf(buf, sizeof(buf), "%.*g", prec, v);
    if (std::strtod(buf, nullptr) == v) {
      break;
    }
  }
  return std::string(buf);
}

// Canonical serialization (design station.md 4): UTF-8, object keys
// sorted bytewise (std::string order IS byte order), no insignificant
// whitespace, minimal JSON escaping. The proxy dedupes registrations by
// a hash of this, so every language must produce identical bytes - the
// `canonical` corpus section carries the adversarial cases. Absent map
// values are dropped (ts filters undefined); null is JSON null.
inline std::string canonical_serialize(const Jval& value) {
  switch (value.type) {
    case Jval::Type::Absent:
    case Jval::Type::Null:
      return "null";
    case Jval::Type::Bool:
      return value.bval ? "true" : "false";
    case Jval::Type::Num:
      return serialize_number(value.nval);
    case Jval::Type::Str:
      return "\"" + escape_json_string(value.sval) + "\"";
    case Jval::Type::List: {
      std::string out = "[";
      for (size_t i = 0; i < value.lval.size(); i++) {
        if (0 < i) {
          out += ",";
        }
        out += canonical_serialize(value.lval[i]);
      }
      return out + "]";
    }
    case Jval::Type::Map: {
      std::vector<std::string> keys;
      for (const auto& entry : value.mval) {
        if (!entry.second.isabsent()) {
          keys.push_back(entry.first);
        }
      }
      std::sort(keys.begin(), keys.end());
      std::string out = "{";
      bool first = true;
      for (const auto& key : keys) {
        if (!first) {
          out += ",";
        }
        first = false;
        out += "\"" + escape_json_string(key) + "\":" + canonical_serialize(value.get(key));
      }
      return out + "}";
    }
  }
  return "null";
}

// A small strict JSON parser (station.json profiles). The library must
// not depend on a JSON library being installed - inside a generated SDK
// one is vendored, standalone there is none.
namespace jsonparse {

inline void skipws(const std::string& text, size_t& pos) {
  while (pos < text.size()) {
    char ch = text[pos];
    if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
      pos++;
    } else {
      break;
    }
  }
}

inline Jval parseval(const std::string& text, size_t& pos);

inline void parseword(const std::string& text, size_t& pos, const std::string& word) {
  if (0 != text.compare(pos, word.size(), word)) {
    throw StationError("station_protocol", "bad JSON literal at " + std::to_string(pos));
  }
  pos += word.size();
}

inline std::string parsestr(const std::string& text, size_t& pos) {
  if (pos >= text.size() || '"' != text[pos]) {
    throw StationError("station_protocol", "expected JSON string at " + std::to_string(pos));
  }
  pos++;
  std::string out;
  while (pos < text.size()) {
    char ch = text[pos++];
    if ('"' == ch) {
      return out;
    }
    if ('\\' != ch) {
      out.push_back(ch);
      continue;
    }
    if (pos >= text.size()) {
      break;
    }
    char escape = text[pos++];
    switch (escape) {
      case '"': out.push_back('"'); break;
      case '\\': out.push_back('\\'); break;
      case '/': out.push_back('/'); break;
      case 'b': out.push_back('\b'); break;
      case 'f': out.push_back('\f'); break;
      case 'n': out.push_back('\n'); break;
      case 'r': out.push_back('\r'); break;
      case 't': out.push_back('\t'); break;
      case 'u': {
        if (pos + 4 > text.size()) {
          throw StationError("station_protocol", "bad JSON unicode escape");
        }
        unsigned int code =
            static_cast<unsigned int>(std::stoul(text.substr(pos, 4), nullptr, 16));
        pos += 4;
        if (0x80 > code) {
          out.push_back(static_cast<char>(code));
        } else if (0x800 > code) {
          out.push_back(static_cast<char>(0xC0 | (code >> 6)));
          out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
        } else {
          out.push_back(static_cast<char>(0xE0 | (code >> 12)));
          out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
          out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
        }
        break;
      }
      default:
        throw StationError("station_protocol", "bad JSON escape at " + std::to_string(pos));
    }
  }
  throw StationError("station_protocol", "unterminated JSON string");
}

inline Jval parsemap(const std::string& text, size_t& pos) {
  Jval out = Jval::map();
  pos++;  // {
  skipws(text, pos);
  if (pos < text.size() && '}' == text[pos]) {
    pos++;
    return out;
  }
  for (;;) {
    skipws(text, pos);
    std::string key = parsestr(text, pos);
    skipws(text, pos);
    if (pos >= text.size() || ':' != text[pos]) {
      throw StationError("station_protocol", "expected ':' at " + std::to_string(pos));
    }
    pos++;
    skipws(text, pos);
    out.set(key, parseval(text, pos));
    skipws(text, pos);
    if (pos >= text.size()) {
      throw StationError("station_protocol", "unterminated JSON object");
    }
    if (',' == text[pos]) {
      pos++;
      continue;
    }
    if ('}' == text[pos]) {
      pos++;
      return out;
    }
    throw StationError("station_protocol", "expected ',' or '}' at " + std::to_string(pos));
  }
}

inline Jval parselist(const std::string& text, size_t& pos) {
  Jval out = Jval::list();
  pos++;  // [
  skipws(text, pos);
  if (pos < text.size() && ']' == text[pos]) {
    pos++;
    return out;
  }
  for (;;) {
    skipws(text, pos);
    out.push(parseval(text, pos));
    skipws(text, pos);
    if (pos >= text.size()) {
      throw StationError("station_protocol", "unterminated JSON array");
    }
    if (',' == text[pos]) {
      pos++;
      continue;
    }
    if (']' == text[pos]) {
      pos++;
      return out;
    }
    throw StationError("station_protocol", "expected ',' or ']' at " + std::to_string(pos));
  }
}

inline Jval parsenum(const std::string& text, size_t& pos) {
  size_t start = pos;
  if (pos < text.size() && ('-' == text[pos] || '+' == text[pos])) {
    pos++;
  }
  while (pos < text.size()) {
    char ch = text[pos];
    if (std::isdigit(static_cast<unsigned char>(ch)) || '.' == ch || 'e' == ch ||
        'E' == ch || '-' == ch || '+' == ch) {
      pos++;
    } else {
      break;
    }
  }
  std::string span = text.substr(start, pos - start);
  try {
    return Jval::num(std::stod(span));
  } catch (const std::exception&) {
    throw StationError("station_protocol", "bad JSON number [" + span + "]");
  }
}

inline Jval parseval(const std::string& text, size_t& pos) {
  if (pos >= text.size()) {
    throw StationError("station_protocol", "unexpected end of JSON");
  }
  char ch = text[pos];
  if ('{' == ch) return parsemap(text, pos);
  if ('[' == ch) return parselist(text, pos);
  if ('"' == ch) return Jval::str(parsestr(text, pos));
  if ('t' == ch) {
    parseword(text, pos, "true");
    return Jval::boolean(true);
  }
  if ('f' == ch) {
    parseword(text, pos, "false");
    return Jval::boolean(false);
  }
  if ('n' == ch) {
    parseword(text, pos, "null");
    return Jval::null();
  }
  return parsenum(text, pos);
}

}  // namespace jsonparse

inline Jval parse_json(const std::string& text) {
  size_t pos = 0;
  jsonparse::skipws(text, pos);
  Jval out = jsonparse::parseval(text, pos);
  jsonparse::skipws(text, pos);
  if (pos < text.size()) {
    throw StationError("station_protocol", "trailing JSON content at " + std::to_string(pos));
  }
  return out;
}

// ---------------------------------------------------------------------
// The descriptor (design station.md 4): a VIEW over the SDK's embedded
// config, normalized - never a second model. Legacy configs (no
// main.slug/version/target) get fixed sentinels plus a warning.
// ---------------------------------------------------------------------

struct Normalized {
  Jval descriptor;
  std::vector<std::string> warnings;
};

// Stringify a scalar the way ts String(v) reads in the config cases.
inline std::string scalar_str(const Jval& v) {
  if (v.isstr()) return v.sval;
  if (v.isnum()) return serialize_number(v.nval);
  if (v.isbool()) return v.bval ? "true" : "false";
  if (v.isnull()) return "null";
  return "";
}

inline Normalized normalize_descriptor(const Jval& config, const Jval& active_features) {
  Normalized out;

  Jval main = config.get("main");
  Jval options = config.get("options");

  std::string name = main.get("name").str_or("");

  Jval slugval = main.get("slug");
  std::string slug;
  if (slugval.isstr() && !slugval.sval.empty()) {
    slug = slugval.sval;
  } else {
    slug = legacy_slug(name);
    out.warnings.push_back(
        "descriptor: legacy config has no main.slug; derived \"" + slug +
        "\" from the camel name - hyphens in the original name are lost");
  }

  Jval vv = main.get("version");
  std::string version = vv.isnone() ? "0.0.0" : scalar_str(vv);
  Jval tv = main.get("target");
  std::string target = tv.isnone() ? "unknown" : scalar_str(tv);

  // server: sorted server-variable names.
  Jval server = Jval::list();
  Jval svr = options.get("server");
  if (svr.ismap()) {
    std::vector<std::string> keys;
    for (const auto& entry : svr.mval) keys.push_back(entry.first);
    std::sort(keys.begin(), keys.end());
    for (const auto& key : keys) {
      Jval item = Jval::map();
      item.set("name", Jval::str(key));
      item.set("value", Jval::str(scalar_str(svr.get(key))));
      server.push(item);
    }
  }

  // ts: authActive = null != options.auth (present and not null).
  bool auth_active = !options.get("auth").isnone();
  Jval auth = Jval::map();
  auth.set("active", Jval::boolean(auth_active));
  auth.set("prefix",
           Jval::str(auth_active ? options.get("auth").get("prefix").str_or("") : ""));
  auth.set("secretname", Jval::str(secretname_default(slug)));

  // entities: sorted entity names; fields list -> map; ops sorted with
  // the points array kept (an op can multiplex routes - design 4).
  Jval entities = Jval::map();
  Jval entdefs = config.get("entity");
  if (entdefs.ismap()) {
    std::vector<std::string> enames;
    for (const auto& entry : entdefs.mval) enames.push_back(entry.first);
    std::sort(enames.begin(), enames.end());
    for (const auto& ename : enames) {
      Jval e = entdefs.get(ename);
      Jval fields = Jval::map();
      Jval fdefs = e.get("fields");
      if (fdefs.islist()) {
        for (const auto& f : fdefs.lval) {
          Jval fname = f.get("name");
          if (f.ismap() && !fname.isnone()) {
            Jval fd = Jval::map();
            fd.set("kind", Jval::str(first_truthy_str(f.get("kind"), f.get("type"))));
            fields.set(scalar_str(fname), fd);
          }
        }
      }
      Jval ops = Jval::map();
      Jval opdefs = e.get("op");
      if (opdefs.ismap()) {
        std::vector<std::string> opnames;
        for (const auto& entry : opdefs.mval) opnames.push_back(entry.first);
        std::sort(opnames.begin(), opnames.end());
        for (const auto& opname : opnames) {
          Jval op = opdefs.get(opname);
          Jval points = Jval::list();
          Jval pdefs = op.get("points");
          if (pdefs.islist()) {
            for (const auto& p : pdefs.lval) {
              if (p.isnone() || !p.ismap()) {
                continue;
              }
              Jval point = Jval::map();
              point.set("method", Jval::str(p.get("method").str_or("")));
              point.set("path",
                        Jval::str(first_truthy_str(p.get("orig"), p.get("path"))));
              Jval params = Jval::list();
              Jval parts = p.get("parts");
              if (parts.islist()) {
                for (const auto& part : parts.lval) {
                  if (part.isstr() && !part.sval.empty() && ':' == part.sval[0]) {
                    params.push(Jval::str(part.sval.substr(1)));
                  }
                }
              }
              point.set("params", params);
              Jval select = p.get("select");
              if (!select.isnone() && !select.isabsent()) {
                point.set("select", select);
              }
              points.push(point);
            }
          }
          Jval opout = Jval::map();
          opout.set("points", points);
          ops.set(opname, opout);
        }
      }
      Jval eout = Jval::map();
      eout.set("fields", fields);
      eout.set("ops", ops);
      entities.set(ename, eout);
    }
  }

  // features: present features + active state (from the caller's
  // options.feature map, when given), plus the two fields the
  // descriptor used to throw away (design 7.4):
  //
  //  - `options` is the feature's own declared key set WITH TYPED
  //    DEFAULTS, which is the schema design 8.5 validates against;
  //  - `transport` is the role design 8.4 orders by.
  //
  // Both are already inside the SDK; the descriptor stops discarding
  // them. ADDITIVE, so descriptor v1 consumers are unaffected and the
  // existing `descriptor` corpus section passes unchanged.
  //
  // `transport` is CARRIED rather than inferred: the obvious signal, an
  // empty `hook: {}`, is wrong for station, which both wraps AND
  // dispatches hooks. Until sdkgen emits it the role checks degrade to
  // nothing rather than guessing.
  Jval features = Jval::list();
  Jval fdefs = config.get("feature");
  if (fdefs.ismap()) {
    std::vector<std::string> fnames;
    for (const auto& entry : fdefs.mval) fnames.push_back(entry.first);
    std::sort(fnames.begin(), fnames.end());
    for (const auto& fname : fnames) {
      Jval fdef = fdefs.get(fname);
      Jval f = Jval::map();
      f.set("name", Jval::str(fname));
      Jval factive = active_features.get(fname).get("active");
      f.set("active", Jval::boolean(factive.isbool() && factive.bval));
      Jval fopts = fdef.get("options");
      if (fopts.ismap()) {
        f.set("options", fopts);
      }
      Jval ftransport = fdef.get("transport");
      if (!ftransport.isnone()) {
        std::string role = scalar_str(ftransport);
        if (!role.empty()) {
          f.set("transport", Jval::str(role));
        }
      }
      features.push(f);
    }
  }

  Jval d = Jval::map();
  d.set("station", Jval::num(1));
  d.set("name", Jval::str(name));
  d.set("slug", Jval::str(slug));
  d.set("envtoken", Jval::str(envtoken(slug)));
  d.set("version", Jval::str(version));
  d.set("target", Jval::str(target));
  d.set("base", Jval::str(options.get("base").str_or("")));
  d.set("server", server);
  d.set("auth", auth);
  d.set("entities", entities);
  d.set("features", features);

  out.descriptor = d;
  return out;
}

// ---------------------------------------------------------------------
// The config grammar, as data (design station.md 4).
//
// TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
//
// struct drops the unexpected-key check for a map whose spec node ends
// up EMPTY - "an empty spec object means the object can be open". An
// optional key is `['$ONE','$NIL', spec]`, and when the data does not
// carry that key the validator REMOVES it from the spec node. So a
// block whose keys are all optional degenerates into an open map
// exactly when the data has none of them, and `{"solar": {"bass": 1}}`
// validates clean - the one property the whole exercise is for,
// silently absent in the one case that matters.
//
// So: normalize_config materializes every documented default, and
// validate_config then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
// After normalization every container is present, so the shape can
// require them, so unexpected-key detection is live at every level and
// every error names its path.
//
// A port of typescript/src/shape.ts, which is canonical.
// ---------------------------------------------------------------------

// Map keys in insertion order.
inline std::vector<std::string> keys_of(const Jval& v) {
  std::vector<std::string> out;
  if (v.ismap()) {
    for (const auto& kv : v.mval) {
      out.push_back(kv.first);
    }
  }
  return out;
}

inline std::vector<std::string> sorted_keys_of(const Jval& v) {
  std::vector<std::string> out = keys_of(v);
  std::sort(out.begin(), out.end());
  return out;
}

inline std::string join_strings(const std::vector<std::string>& parts,
                                const std::string& sep) {
  std::string out;
  for (size_t i = 0; i < parts.size(); i++) {
    if (0 < i) {
      out += sep;
    }
    out += parts[i];
  }
  return out;
}

// --- the defaults table - ONE table, two callers ---------------------

// Profile-level containers. Safe to materialize early either way: they
// are containers, and a missing one merges as empty regardless.
inline Jval profile_defaults() {
  Jval out = Jval::map();
  Jval secrets = Jval::map();
  Jval providers = Jval::list();
  Jval env = Jval::map();
  env.set("kind", Jval::str("env"));
  providers.push(env);
  secrets.set("providers", providers);
  out.set("secrets", secrets);
  out.set("api", Jval::map());
  out.set("sdk", Jval::map());
  out.set("feature", Jval::map());
  return out;
}

// Block-level. `feature` is a container and safe early.
//
// `active` IS NOT, and that is the whole timing rule: a default
// synthesized into an OVERLAY block overwrites the base's real value
// and silently reactivates an integration the base deliberately barred
// (design 3.3). So the two consumers read this same table at DIFFERENT
// MOMENTS - validate_config BEFORE, applied to every block, because a
// block with no present keys is an open map; resolve_profile AFTER,
// applied to the merged instance, because an absent key must stay
// absent through the merge.
inline Jval block_defaults() {
  Jval out = Jval::map();
  out.set("active", Jval::boolean(true));
  out.set("feature", Jval::map());
  return out;
}

// The one block key carrying the timing rule. Named rather than
// inferred, so a reader does not have to work out which of the two it
// is, and so a test can assert it.
inline const std::vector<std::string>& merge_sensitive() {
  static const std::vector<std::string> KEYS = {"active"};
  return KEYS;
}

// --- normalize_config ------------------------------------------------

// Per feature entry, at every level: `active` -> true.
//
// A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
// own default is `active: false` for all but `log`, and
// `{"retry": {"retries": 3}}` plainly means "retry, with three
// attempts". It also keeps the feature map closed, for the same reason
// every other block needs one present key.
//
// Defensive like the rest: a non-map is returned untouched for validate
// to reject by path.
inline Jval normfeatures(const Jval& f) {
  if (!f.ismap()) {
    return f;
  }
  Jval out = Jval::map();
  for (const auto& kv : f.mval) {
    if (kv.second.ismap() && !kv.second.has("active")) {
      Jval entry = kv.second;
      entry.set("active", Jval::boolean(true));
      out.set(kv.first, entry);
    } else {
      out.set(kv.first, kv.second);
    }
  }
  return out;
}

// Materialize every documented default, DEFENSIVELY: a node that is not
// the kind it expects is left alone for validate to reject with a
// message that names the path. Pure data-in/data-out, which is what
// makes it portable to sixteen languages and expressible in the corpus.
//
// NEVER MUTATES THE INPUT: Jval is a value type, so every `Jval x = y`
// below is already the copy the dynamic ports make by spreading.
//
// THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE -
// resolve_profile continues to read the RAW config.
inline Jval normalize_config(const Jval& raw) {
  if (!raw.ismap()) {
    return raw;
  }
  Jval out = raw;

  if (!out.has("station")) {
    out.set("station", Jval::num(1));
  }
  if (!out.has("profiles")) {
    out.set("profiles", Jval::map());
  }
  Jval profiles = out.get("profiles");
  if (!profiles.ismap()) {
    return out;
  }

  const Jval pdefaults = profile_defaults();
  const Jval bdefaults = block_defaults();
  static const char* const BLOCKKEYS[] = {"api", "sdk"};

  Jval outprofiles = Jval::map();
  for (const auto& pkv : profiles.mval) {
    if (!pkv.second.ismap()) {
      outprofiles.set(pkv.first, pkv.second);
      continue;
    }
    Jval prof = pkv.second;

    for (const auto& dkv : pdefaults.mval) {
      if (!prof.has(dkv.first)) {
        prof.set(dkv.first, dkv.second);
      }
    }

    // A `secrets` written without `providers` still gets the chain.
    Jval secrets = prof.get("secrets");
    if (secrets.ismap() && !secrets.has("providers")) {
      secrets.set("providers", pdefaults.get("secrets").get("providers"));
      prof.set("secrets", secrets);
    }

    prof.set("feature", normfeatures(prof.get("feature")));

    for (const char* bkey : BLOCKKEYS) {
      Jval blocks = prof.get(bkey);
      if (!blocks.ismap()) {
        continue;
      }
      Jval outblocks = Jval::map();
      for (const auto& bkv : blocks.mval) {
        if (!bkv.second.ismap()) {
          outblocks.set(bkv.first, bkv.second);
          continue;
        }
        Jval block = bkv.second;
        for (const auto& dkv : bdefaults.mval) {
          if (!block.has(dkv.first)) {
            block.set(dkv.first, dkv.second);
          }
        }
        block.set("feature", normfeatures(block.get("feature")));
        outblocks.set(bkv.first, block);
      }
      prof.set(bkey, outblocks);
    }

    outprofiles.set(pkv.first, prof);
  }
  out.set("profiles", outprofiles);
  return out;
}

// --- the shape, and the struct bridge --------------------------------

// --- BEGIN GENERATED: config-shape (cpp/tools/sync-shape.py) ---
// The mirrored bytes of `spec/config-shape.json`, verbatim, so a diff of
// this region reads like a diff of the spec.
inline const char* config_shape_json() {
  static const char* const SHAPE = R"SHAPE({
  "station": [
    "`$EXACT`",
    1
  ],
  "profiles": {
    "`$CHILD`": {
      "secrets": {
        "providers": "`$LIST`"
      },
      "api": {
        "`$CHILD`": {
          "active": "`$BOOLEAN`",
          "package": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "export": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "base": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "secret": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "resolve": [
            "`$ONE`",
            "`$NIL`",
            [
              "`$EXACT`",
              "library"
            ],
            [
              "`$EXACT`",
              "proxy"
            ]
          ],
          "capture": [
            "`$ONE`",
            "`$NIL`",
            [
              "`$EXACT`",
              "meta"
            ],
            [
              "`$EXACT`",
              "headers"
            ],
            [
              "`$EXACT`",
              "full"
            ]
          ],
          "policy": [
            "`$ONE`",
            "`$NIL`",
            {
              "allow": [
                "`$ONE`",
                "`$NIL`",
                {
                  "method": [
                    "`$CHILD`",
                    "`$STRING`"
                  ],
                  "op": [
                    "`$CHILD`",
                    "`$STRING`"
                  ]
                }
              ],
              "budget": [
                "`$ONE`",
                "`$NIL`",
                {
                  "concurrency": [
                    "`$ONE`",
                    "`$NIL`",
                    "`$INTEGER`"
                  ],
                  "rps": [
                    "`$ONE`",
                    "`$NIL`",
                    "`$NUMBER`"
                  ]
                }
              ],
              "hosts": [
                "`$CHILD`",
                "`$STRING`"
              ],
              "mode": [
                "`$ONE`",
                "`$NIL`",
                [
                  "`$EXACT`",
                  "live"
                ],
                [
                  "`$EXACT`",
                  "record"
                ],
                [
                  "`$EXACT`",
                  "replay"
                ],
                [
                  "`$EXACT`",
                  "mock"
                ],
                [
                  "`$EXACT`",
                  "block"
                ]
              ]
            }
          ],
          "agent": [
            "`$ONE`",
            "`$NIL`",
            {
              "write": "`$BOOLEAN`"
            }
          ],
          "options": [
            "`$ONE`",
            "`$NIL`",
            "`$MAP`"
          ],
          "feature": {
            "`$CHILD`": {
              "active": "`$BOOLEAN`",
              "`$OPEN`": true
            }
          }
        }
      },
      "sdk": {
        "`$CHILD`": {
          "active": "`$BOOLEAN`",
          "package": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "export": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "base": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "secret": [
            "`$ONE`",
            "`$NIL`",
            "`$STRING`"
          ],
          "resolve": [
            "`$ONE`",
            "`$NIL`",
            [
              "`$EXACT`",
              "library"
            ],
            [
              "`$EXACT`",
              "proxy"
            ]
          ],
          "capture": [
            "`$ONE`",
            "`$NIL`",
            [
              "`$EXACT`",
              "meta"
            ],
            [
              "`$EXACT`",
              "headers"
            ],
            [
              "`$EXACT`",
              "full"
            ]
          ],
          "policy": [
            "`$ONE`",
            "`$NIL`",
            {
              "allow": [
                "`$ONE`",
                "`$NIL`",
                {
                  "method": [
                    "`$CHILD`",
                    "`$STRING`"
                  ],
                  "op": [
                    "`$CHILD`",
                    "`$STRING`"
                  ]
                }
              ],
              "budget": [
                "`$ONE`",
                "`$NIL`",
                {
                  "concurrency": [
                    "`$ONE`",
                    "`$NIL`",
                    "`$INTEGER`"
                  ],
                  "rps": [
                    "`$ONE`",
                    "`$NIL`",
                    "`$NUMBER`"
                  ]
                }
              ],
              "hosts": [
                "`$CHILD`",
                "`$STRING`"
              ],
              "mode": [
                "`$ONE`",
                "`$NIL`",
                [
                  "`$EXACT`",
                  "live"
                ],
                [
                  "`$EXACT`",
                  "record"
                ],
                [
                  "`$EXACT`",
                  "replay"
                ],
                [
                  "`$EXACT`",
                  "mock"
                ],
                [
                  "`$EXACT`",
                  "block"
                ]
              ]
            }
          ],
          "agent": [
            "`$ONE`",
            "`$NIL`",
            {
              "write": "`$BOOLEAN`"
            }
          ],
          "options": [
            "`$ONE`",
            "`$NIL`",
            "`$MAP`"
          ],
          "feature": {
            "`$CHILD`": {
              "active": "`$BOOLEAN`",
              "`$OPEN`": true
            }
          }
        }
      },
      "feature": {
        "`$CHILD`": {
          "active": "`$BOOLEAN`",
          "order": {
            "before": [
              "`$ONE`",
              "`$NIL`",
              "`$STRING`",
              [
                "`$CHILD`",
                "`$STRING`"
              ]
            ],
            "after": [
              "`$ONE`",
              "`$NIL`",
              "`$STRING`",
              [
                "`$CHILD`",
                "`$STRING`"
              ]
            ],
            "band": [
              "`$ONE`",
              "`$NIL`",
              "`$INTEGER`"
            ]
          },
          "`$OPEN`": true
        }
      }
    }
  }
}
)SHAPE";
  return SHAPE;
}
// --- END GENERATED: config-shape ---

// A FRESH DEEP COPY ON EVERY CALL, and that is not an optimization left
// undone: struct's validate CONSUMES the spec it walks - it deletes
// satisfied `$ONE` branches as it goes - so handing it one parsed
// constant twice validates the second config against a spec the first
// already ate. Re-parsing the mirror IS the copy.
inline Jval config_shape() { return parse_json(config_shape_json()); }

namespace detail {

// Jval -> struct's own value model. INTEGER-SHAPED NUMBERS STAY
// INTEGERS: struct's `$INTEGER` checker and its error spellings ("found
// integer: 8080" rather than "found decimal") both read the
// distinction, and Jval carries one double for both.
inline ::voxgig::structlib::Value to_struct(const Jval& v) {
  namespace vsx = ::voxgig::structlib;
  switch (v.type) {
    case Jval::Type::Absent:
      return vsx::Value::undef();
    case Jval::Type::Null:
      return vsx::Value(nullptr);
    case Jval::Type::Bool:
      return vsx::Value(v.bval);
    case Jval::Type::Num:
      if (v.nval == std::floor(v.nval) && std::fabs(v.nval) < 9007199254740992.0) {
        return vsx::Value(static_cast<int64_t>(v.nval));
      }
      return vsx::Value(v.nval);
    case Jval::Type::Str:
      return vsx::Value(v.sval);
    case Jval::Type::List: {
      vsx::Value out = vsx::Value::list();
      for (const auto& item : v.lval) {
        out.as_list()->push_back(to_struct(item));
      }
      return out;
    }
    case Jval::Type::Map: {
      vsx::Value out = vsx::Value::map();
      for (const auto& kv : v.mval) {
        if (kv.second.isabsent()) {
          continue;  // absent is absent, as in the canonical serializer
        }
        out.as_map()->set(kv.first, to_struct(kv.second));
      }
      return out;
    }
  }
  return vsx::Value::undef();
}

// A design 4.4 workaround of the same family as firstelement below, and
// recorded here for the same reason: the corpus pins a spelling, and
// this port must produce it whatever struct version is vendored.
//
// Canonical struct lowers a spec term's `$NAME` to a bare `name` across
// the WHOLE joined description (StructUtility.ts validate_ONE:
// `replace(join(...), R_TRANSFORM_NAME, lowercase)`), so
// `[`$EXACT`,library]` reads `[exact,library]`. THE C++ PORT OF STRUCT
// APPLIES IT PER TOP-LEVEL TERM ONLY, so a nested list or map term
// keeps its backticked names - `config#resolve-is-an-enum`,
// `config#policy-typo-is-the-generic-one-form`,
// `config#order-list-element-type`,
// `config#capture-depth-must-be-a-known-depth` and
// `config#agent-block-stays-closed` all pin the canonical spelling and
// all five see the raw one. struct's own corpus has no `$ONE` carrying
// a compound term, which is why the gap is untested upstream.
//
// So the replacement is finished here, over CANONICAL'S OWN SCOPE and
// no wider: the `need_type` span of struct's message, which sits
// between the first " to be " and the last ", but found " (see
// invalid_type_msg). A `$NAME` in the offending VALUE half is left
// alone. Remove this when struct's C++ port lowers the joined
// description, not before - the corpus entries above are what will say
// so.
inline std::string pin_spec_names(const std::string& msg) {
  static const std::string TOBE = " to be ";
  static const std::string FOUND = ", but found ";
  static const std::string EXPECTED = "Expected ";

  size_t end = msg.rfind(FOUND);
  if (std::string::npos == end) {
    return msg;
  }
  size_t start;
  size_t tobe = msg.find(TOBE);
  if (std::string::npos != tobe && tobe < end) {
    start = tobe + TOBE.size();
  } else if (0 == msg.compare(0, EXPECTED.size(), EXPECTED)) {
    start = EXPECTED.size();
  } else {
    return msg;
  }

  std::string out = msg.substr(0, start);
  size_t at = start;
  while (at < end) {
    if ('`' == msg[at] && at + 1 < end && '$' == msg[at + 1]) {
      size_t scan = at + 2;
      while (scan < end && std::isupper(static_cast<unsigned char>(msg[scan]))) {
        scan++;
      }
      if (scan > at + 2 && scan < end && '`' == msg[scan]) {
        for (size_t i = at + 2; i < scan; i++) {
          out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(msg[i]))));
        }
        at = scan + 1;
        continue;
      }
    }
    out.push_back(msg[at]);
    at++;
  }
  return out + msg.substr(end);
}

// Run the shape. Appends struct's own error strings, IN ENCOUNTER
// ORDER, to `errs` - the order `config#every-error-at-once` pins.
inline void runshape(const Jval& normalized, std::vector<std::string>& errs) {
  namespace vsx = ::voxgig::structlib;
  vsx::Value data = to_struct(normalized);
  vsx::Value spec = to_struct(config_shape());
  vsx::Value collected = vsx::Value::list();
  vsx::Value opts = vsx::Value::map();
  // The errs collection is what makes struct COLLECT rather than throw
  // at the first problem, which is what "every error at once" needs.
  opts.as_map()->set("errs", collected);

  std::string thrown;
  try {
    vsx::validate(data, spec, opts);
  } catch (const std::exception& err) {
    thrown = err.what();
  }

  for (const auto& item : *collected.as_list()) {
    errs.push_back(
        pin_spec_names(item.is_string() ? item.as_string() : vsx::stringify(item)));
  }
  // A collecting validate does not throw for a validation failure, so
  // anything that arrives here is struct itself giving up - reported
  // rather than swallowed, and only when it left nothing collected.
  if (!thrown.empty() && errs.empty()) {
    errs.push_back(thrown);
  }
}

}  // namespace detail

// --- the design 5.2 / 4.4 scans --------------------------------------

// Credential-shaped keys (design 5.2). `secret` is here AND is the one
// exempt key - see secretvalue below; a blanket deny would reject the
// very mechanism that keeps values out of the file.
inline const std::vector<std::string>& credential_keys() {
  static const std::vector<std::string> KEYS = {
      "apikey", "auth", "authorization", "token",
      "secret", "password", "credential", "bearer",
  };
  return KEYS;
}

// The suffix rule catches `access_key`, `X-Api-Token` and friends in
// one rule rather than a growing list of spellings.
inline const std::vector<std::string>& credential_suffix() {
  static const std::vector<std::string> SUFFIX = {"_KEY", "_TOKEN", "_SECRET",
                                                  "_PASSWORD"};
  return SUFFIX;
}

// Design 5.2's backstop, stated as a bound rather than a grammar.
// `validname()` is a NAME grammar, not a credential filter: it rejects
// uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
// credential formats - but a lowercase hex token passes it cleanly. A
// character class cannot tell a name from a secret.
//
// Derived names break on every separator (`voxgig_solardemo.apikey`
// runs 6/9/6) and a hand-written name for a human to read does too; a
// 24-character unbroken run is not a name anybody writes. Note this is
// a RUN bound, not a length bound: `acme_internal_billing_service.apikey`
// is 36 characters and passes, which is the false positive a naive
// length bound would produce.
inline constexpr int RUN_BOUND = 24;

inline bool unbroken_run(const std::string& s) {
  int run = 0;
  for (unsigned char c : s) {
    if (std::isalnum(c)) {
      run++;
      if (RUN_BOUND <= run) {
        return true;
      }
    } else {
      run = 0;
    }
  }
  return false;
}

// The SHAPE kindof: it must agree with struct's own spellings, because
// the design 4.4 workarounds below raise the message the shape would
// have raised. NOT the FEATURE kindof of design 8.5 (feature_kindof,
// further down) - "object"/"integer" here against "map"/"number" there
// - and unifying the two would make one of the two sets of messages
// wrong.
inline std::string shape_kindof(const Jval& v) {
  switch (v.type) {
    case Jval::Type::Null:
      return "null";
    case Jval::Type::List:
      return "list";
    case Jval::Type::Num:
      return (v.nval == std::floor(v.nval) && std::fabs(v.nval) < 9007199254740992.0)
                 ? "integer"
                 : "decimal";
    case Jval::Type::Map:
      return "object";
    case Jval::Type::Bool:
      return "boolean";
    case Jval::Type::Str:
      return "string";
    default:
      return "undefined";
  }
}

namespace detail {

inline std::string lowercase(const std::string& s) {
  std::string out = s;
  std::transform(out.begin(), out.end(), out.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return out;
}

inline bool endswith(const std::string& s, const std::string& tail) {
  return s.size() >= tail.size() && 0 == s.compare(s.size() - tail.size(), tail.size(), tail);
}

// A `secret`-named key holds a NAME, and that exemption is not a
// loophole - it is the whole design. THREE checks, not one, in this
// order, first failure winning, and they live in the same handful of
// lines precisely so a port cannot implement only the first and inherit
// the gap the others close.
inline void secretvalue(const Jval& val, const std::string& path,
                        std::vector<std::string>& secrets) {
  if (!val.isstr()) {
    secrets.push_back(path + " must be a secret name (a string), but found " +
                      shape_kindof(val));
    return;
  }
  if (!validname(val.sval)) {
    secrets.push_back(path +
                      " is not a valid sekreto name, so it cannot be a name and "
                      "must not be a value: " +
                      canonical_serialize(val));
    return;
  }
  if (unbroken_run(val.sval)) {
    secrets.push_back(path +
                      " contains an unbroken alphanumeric run of 24 or more "
                      "characters, which is not a name anybody writes");
  }
}

// One rule about VALUES rather than keys, because the `proxy` feature
// makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
// failure is not an error - it returns silently.
inline void userinfo(const Jval& val, const std::string& path,
                     std::vector<std::string>& secrets) {
  if (!val.isstr()) {
    return;
  }
  const std::string& s = val.sval;

  // ^[a-zA-Z][a-zA-Z0-9+.-]*://
  if (s.empty() || !std::isalpha(static_cast<unsigned char>(s[0]))) {
    return;
  }
  size_t at = 1;
  while (at < s.size()) {
    unsigned char c = static_cast<unsigned char>(s[at]);
    if (std::isalnum(c) || '+' == c || '.' == c || '-' == c) {
      at++;
      continue;
    }
    break;
  }
  if (0 != s.compare(at, 3, "://")) {
    return;
  }

  size_t astart = at + 3;
  size_t aend = s.find_first_of("/?#", astart);
  if (std::string::npos == aend) {
    aend = s.size();
  }
  // Everything before the LAST `@` in the authority is the userinfo.
  size_t marker = s.rfind('@', 0 == aend ? 0 : aend - 1);
  if (std::string::npos == marker || marker < astart || marker >= aend ||
      marker == astart) {
    return;
  }

  secrets.push_back(path +
                    " is a URL carrying userinfo, which puts a credential in the "
                    "config file; use the proxy feature's `fromEnv` option "
                    "instead (design 8.6)");
}

inline bool credentialkey(const std::string& key) {
  std::string low;
  for (unsigned char c : key) {
    unsigned char lc = static_cast<unsigned char>(std::tolower(c));
    if (std::isalnum(lc)) {
      low.push_back(static_cast<char>(lc));
    }
  }
  const auto& keys = credential_keys();
  if (std::find(keys.begin(), keys.end(), low) != keys.end()) {
    return true;
  }
  std::string tok = envtoken(key);
  for (const auto& suffix : credential_suffix()) {
    if (endswith(tok, suffix)) {
      return true;
    }
  }
  return false;
}

// RECURSIVE OVER EVERY NESTED MAP AND LIST, not just the top level - a
// credential one level down is the case a top-level scan misses.
inline void scan(const Jval& node, const std::string& path,
                 std::vector<std::string>& secrets, std::vector<std::string>& reserved) {
  if (node.islist()) {
    for (size_t i = 0; i < node.lval.size(); i++) {
      scan(node.lval[i], path + "." + std::to_string(i), secrets, reserved);
    }
    return;
  }
  if (node.isstr()) {
    userinfo(node, path, secrets);
    return;
  }
  if (!node.ismap()) {
    return;
  }

  for (const auto& kv : node.mval) {
    const std::string kpath = path + "." + kv.first;

    // Design 8.6: station owns feature composition, so an
    // `options.feature` in a declarative config is a second,
    // unreconciled ordering input.
    if ("feature" == kv.first) {
      reserved.push_back(kpath +
                         " is reserved: configure features under the block's own "
                         "`feature` key, not through `options`");
      continue;
    }

    if ("secret" == lowercase(kv.first)) {
      secretvalue(kv.second, kpath, secrets);
      continue;
    }

    if (credentialkey(kv.first)) {
      secrets.push_back(kpath +
                        " is a credential-shaped key: station.json holds secret "
                        "NAMES, never values (design 5.2)");
      continue;
    }

    scan(kv.second, kpath, secrets, reserved);
  }
}

// Design 4.4: `$CHILD` in list mode DOES NOT VALIDATE ELEMENT 0.
// Verified: `["a", 1]` fails at index 1, `[1]` passes, at any list
// length. Filed upstream as voxgig/struct#113.
//
// It reaches THREE string lists in this shape: `policy.hosts`, and the
// per-feature `order.before` and `order.after`. Applied where the shape
// cannot reach, raising the same code the shape would, and PINNED IN
// THE CORPUS so the workaround is removed deliberately when struct is
// fixed rather than forgotten.
inline void firstelement(const Jval& list, const std::string& path,
                         std::vector<std::string>& invalid) {
  if (!list.islist() || list.lval.empty()) {
    return;
  }
  if (list.lval[0].isstr()) {
    return;
  }
  invalid.push_back("Expected field " + path + ".0 to be string, but found " +
                    shape_kindof(list.lval[0]) + ": " +
                    canonical_serialize(list.lval[0]));
}

// The policy block's design 4.4 workarounds, in one place because they
// are one class of gap: struct cannot check what its own defects hide.
//
// - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists,
//   so element 0 escapes the shape (see firstelement above).
// - `budget` is a map whose keys are ALL optional scalars, and struct
//   removes an unsatisfied optional key from the spec node - so
//   `budget: {rp: 1}` degenerates the spec into an open map and the
//   typo passes. `allow` does not have this problem (its `$CHILD` keys
//   stay in the spec whether or not the data carries them, keeping the
//   map closed), and neither does `policy` itself (`hosts` anchors it);
//   `budget` alone needs the explicit unexpected-key check, phrased as
//   struct would phrase it.
inline void checkpolicy(const Jval& policy, const std::string& path,
                        std::vector<std::string>& invalid) {
  static const std::vector<std::string> BUDGET_KEYS = {"concurrency", "rps"};

  if (!policy.ismap()) {
    return;
  }

  firstelement(policy.get("hosts"), path + ".hosts", invalid);

  Jval allow = policy.get("allow");
  if (allow.ismap()) {
    firstelement(allow.get("op"), path + ".allow.op", invalid);
    firstelement(allow.get("method"), path + ".allow.method", invalid);
  }

  Jval budget = policy.get("budget");
  if (budget.ismap()) {
    std::vector<std::string> unknown;
    for (const auto& key : sorted_keys_of(budget)) {
      if (std::find(BUDGET_KEYS.begin(), BUDGET_KEYS.end(), key) == BUDGET_KEYS.end()) {
        unknown.push_back(key);
      }
    }
    if (!unknown.empty()) {
      invalid.push_back("Unexpected keys at field " + path + ".budget: " +
                        join_strings(unknown, ", "));
    }
  }
}

// A feature map at any level. `station` is reserved: station composes
// its own wrap and a config that reconfigures it is asking for a state
// the ordering rules cannot express (design 8.4) - and a config file
// that can switch off the component reading it is not a surface, it is
// a trap.
inline void checkfeatures_scan(const Jval& f, const std::string& path,
                               std::vector<std::string>& secrets,
                               std::vector<std::string>& reserved,
                               std::vector<std::string>& invalid) {
  if (!f.ismap()) {
    return;
  }
  for (const auto& kv : f.mval) {
    if ("station" == kv.first) {
      reserved.push_back(path +
                         ".station is reserved: station composes its own wrap and "
                         "it cannot be configured from station.json");
    }
    const std::string fpath = path + "." + kv.first;
    Jval order = kv.second.ismap() ? kv.second.get("order") : Jval::absent();
    if (order.ismap()) {
      firstelement(order.get("before"), fpath + ".order.before", invalid);
      firstelement(order.get("after"), fpath + ".order.after", invalid);
    }
    scan(kv.second, fpath, secrets, reserved);
  }
}

// The design 5.2 scans, over the parts of the grammar that hold
// arbitrary data. Everything else is closed by construction and needs
// no scan - and `profiles.<p>.secrets.providers` IS NOT SCANNED:
// provider blocks legitimately carry an `auth` sub-map ({method, role}),
// and config#twenty-sdk-fleet passes only because the scan does not
// reach there. Collects rather than throwing - the caller owns the
// throw order.
inline void scanconfig(const Jval& cfg, std::vector<std::string>& secrets,
                       std::vector<std::string>& reserved,
                       std::vector<std::string>& invalid) {
  static const char* const BLOCKKEYS[] = {"api", "sdk"};

  Jval profiles = cfg.get("profiles");
  if (!profiles.ismap()) {
    return;
  }

  for (const auto& pkv : profiles.mval) {
    const Jval& prof = pkv.second;
    if (!prof.ismap()) {
      continue;
    }
    const std::string ppath = "profiles." + pkv.first;

    checkfeatures_scan(prof.get("feature"), ppath + ".feature", secrets, reserved,
                       invalid);

    for (const char* bkey : BLOCKKEYS) {
      Jval blocks = prof.get(bkey);
      if (!blocks.ismap()) {
        continue;
      }
      for (const auto& bkv : blocks.mval) {
        const Jval& block = bkv.second;
        if (!block.ismap()) {
          continue;
        }
        const std::string bpath = ppath + "." + bkey + "." + bkv.first;

        // The block's own `secret` holds a NAME. resolve_profile checks
        // it again per instance (station_secret_name); this catches it
        // at open(), for the whole file at once.
        if (block.has("secret")) {
          secretvalue(block.get("secret"), bpath + ".secret", secrets);
        }

        // `options` is passthrough to a generated constructor, so it is
        // the one place a value can hide.
        scan(block.get("options"), bpath + ".options", secrets, reserved);
        checkfeatures_scan(block.get("feature"), bpath + ".feature", secrets, reserved,
                           invalid);
        checkpolicy(block.get("policy"), bpath + ".policy", invalid);
      }
    }
  }
}

// `plugin` is REMOVED, not aliased (design 3.4) - a deprecated alias
// would be a second grammar for one concept in sixteen ports. The shape
// already rejects it as an unexpected key; this says WHAT TO RENAME,
// because "unexpected key: plugin" alone does not, and the migration
// for a single-instance project is exactly this one rename.
inline std::string renamehint(const Jval& cfg) {
  Jval profiles = cfg.get("profiles");
  if (!profiles.ismap()) {
    return "";
  }
  std::vector<std::string> hit;
  for (const auto& pkv : profiles.mval) {
    if (pkv.second.ismap() && pkv.second.has("plugin")) {
      hit.push_back("profiles." + pkv.first);
    }
  }
  if (hit.empty()) {
    return "";
  }
  return "; rename `plugin` to `sdk` in " + join_strings(hit, ", ") +
         " - the keys are unchanged, an untagged ref IS an api slug (design 3.4)";
}

}  // namespace detail

// Normalize, then validate (design 4.2). Raises station_config_invalid
// with EVERY error at once - an eighteen-instance config that touches
// three of them must not die because the eighteenth has a typo'd
// package name.
//
// The design 4.4 workarounds are merged into the SAME throw as struct's
// own errors: a struct new enough to reject a first-element gap itself
// reports a DIFFERENT spelling ("to be one of ..."), and the corpus
// pins the explicit one - so the pinned message is produced here either
// way, and behaviour is identical whatever struct version is vendored.
//
// Takes the NORMALIZED form. Handing it a raw config is the mistake
// design 4.2 exists to prevent, so every caller goes through
// normalize_config first (Station's constructor does exactly
// validate_config(normalize_config(config))).
inline Jval validate_config(const Jval& normalized) {
  std::vector<std::string> errs;
  detail::runshape(normalized, errs);

  std::vector<std::string> secrets;
  std::vector<std::string> reserved;
  std::vector<std::string> invalid;
  detail::scanconfig(normalized, secrets, reserved, invalid);

  if (!errs.empty() || !invalid.empty()) {
    std::vector<std::string> all = errs;
    all.insert(all.end(), invalid.begin(), invalid.end());
    throw StationError("station_config_invalid",
                       join_strings(all, "; ") + detail::renamehint(normalized));
  }
  if (!reserved.empty()) {
    throw StationError("station_feature_reserved", join_strings(reserved, "; "));
  }
  if (!secrets.empty()) {
    throw StationError("station_config_secret", join_strings(secrets, "; "));
  }
  return normalized;
}

// ---------------------------------------------------------------------
// Feature management (design station.md 8): the three-level merge, the
// constraint-and-band resolver, and the descriptor-derived checker.
//
// A port of typescript/src/feature.ts, which is canonical.
// ---------------------------------------------------------------------

// Reserved on a feature entry: not options, and never passed through to
// the SDK's own option map.
inline const std::vector<std::string>& reserved_keys() {
  static const std::vector<std::string> KEYS = {"active", "order"};
  return KEYS;
}

// `test` substitutes the base transport, so it takes the innermost
// band; `station` sits immediately outside it, pinned; everything else
// is band 0, outside station. HIGHER IS FURTHER IN.
//
// THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
// than as a special case: a project that writes no `order` anywhere
// sees exactly today's nesting.
inline constexpr int BAND_DEFAULT = 0;
inline constexpr int BAND_STATION = 100;
inline constexpr int BAND_TEST = 200;

inline int default_band(const std::string& name) {
  if ("test" == name) {
    return BAND_TEST;
  }
  if ("station" == name) {
    return BAND_STATION;
  }
  return BAND_DEFAULT;
}

// A feature named in the config is one you are ASKING for, so an entry
// with no `active` is active.
inline bool feature_active(const Jval& entry) {
  if (!entry.ismap()) {
    return !(entry.isbool() && !entry.bval);
  }
  Jval a = entry.get("active");
  return !(a.isbool() && !a.bval);
}

// `feature` is the ONE key where design 3.3's shallow-per-key rule is
// wrong: composition is the entire point, a fleet default plus a
// per-instance tweak. So it is a TWO-LEVEL merge - per feature name,
// then per option key - AND NO DEEPER. A map-valued option REPLACES
// wholesale, which is what `{"$MERGE": {"deep": 2}}` states and what a
// port defaulting to a deep merge would silently get wrong.
//
// NO DEFAULTS ARE SYNTHESIZED HERE, which is why the caller passes RAW
// blocks: an entry mentioned at one level with only a tuning key must
// NOT synthesize `active` and switch on a feature a broader level
// turned off. That is the design 3.3 defect one level down.
inline Jval merge_features(const std::vector<Jval>& sources) {
  Jval out = Jval::map();
  for (const auto& src : sources) {
    if (!src.ismap()) {
      continue;
    }
    for (const auto& kv : src.mval) {
      if (!kv.second.ismap()) {
        out.set(kv.first, kv.second);  // a non-map entry replaces wholesale
        continue;
      }
      Jval prior = out.get(kv.first);
      Jval entry = prior.ismap() ? prior : Jval::map();
      for (const auto& okv : kv.second.mval) {
        entry.set(okv.first, okv.second);  // per option key, and NOT deeper
      }
      out.set(kv.first, entry);
    }
  }
  return out;
}

// The six sources for one instance, in design 3.3's order extended by
// the profile level:
//
//   1 base.feature            4 overlay.feature
//   2 base.api[<api>].feature 5 overlay.api[<api>].feature
//   3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
//
// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
// the narrower block wins. Assembled here rather than at the call site
// so the order lives in exactly one place.
inline std::vector<Jval> feature_sources(const Jval& base, const Jval& overlay,
                                         const std::string& api, const std::string& ref) {
  return {
      base.get("feature"),
      base.get("api").get(api).get("feature"),
      base.get("sdk").get(ref).get("feature"),
      overlay.get("feature"),
      overlay.get("api").get(api).get("feature"),
      overlay.get("sdk").get(ref).get("feature"),
  };
}

// One row of the resolved order, OUTERMOST FIRST.
struct Ordered {
  std::string name;
  double band = 0;
  Jval entry;
};

namespace detail {

// `before`/`after` take a feature name or a list of them.
inline std::vector<std::string> listof(const Jval& v) {
  std::vector<std::string> out;
  if (v.isnone()) {
    return out;
  }
  if (v.islist()) {
    for (const auto& item : v.lval) {
      out.push_back(scalar_str(item));
    }
    return out;
  }
  out.push_back(scalar_str(v));
  return out;
}

}  // namespace detail

// Resolve the activation order: constraints, then bands, then the
// feature's position in the merged map.
//
// `before`/`after` are SATISFIED VACUOUSLY when the named feature is
// absent - `after: 'test'` loads fine in a project with no test
// feature, which is sdkgen's `__after__` behaviour kept rather than
// reinvented.
//
// Constraints beat bands; bands break ties no constraint decides;
// remaining ties break by DECLARATION POSITION, so the result is a
// stable topological sort with no alphabetical accident in it.
//
// Returns OUTERMOST FIRST, which is the array form the constructor
// takes and the direction the chain composes in.
inline std::vector<Ordered> resolve_order(const Jval& merged) {
  std::vector<std::string> names;
  for (const auto& kv : merged.mval) {
    if (feature_active(kv.second)) {
      names.push_back(kv.first);
    }
  }

  std::map<std::string, size_t> pos;
  std::map<std::string, double> band;
  for (size_t i = 0; i < names.size(); i++) {
    pos[names[i]] = i;
    Jval entry = merged.get(names[i]);
    Jval order = entry.ismap() ? entry.get("order") : Jval::absent();
    Jval b = order.ismap() ? order.get("band") : Jval::absent();
    band[names[i]] = b.isnum() ? b.nval : static_cast<double>(default_band(names[i]));
  }

  // edges: from OUTER to INNER. `after: X` means "further in than X".
  std::map<std::string, std::set<std::string>> inner;
  for (const auto& n : names) {
    inner[n];
  }
  for (const auto& n : names) {
    Jval entry = merged.get(n);
    Jval order = entry.ismap() ? entry.get("order") : Jval::absent();
    if (!order.ismap()) {
      continue;
    }
    for (const auto& other : detail::listof(order.get("after"))) {
      if (0 < inner.count(other)) {
        inner[other].insert(n);
      }
    }
    for (const auto& other : detail::listof(order.get("before"))) {
      if (0 < inner.count(other)) {
        inner[n].insert(other);
      }
    }
  }

  std::map<std::string, int> indeg;
  for (const auto& n : names) {
    indeg[n] = 0;
  }
  for (const auto& n : names) {
    for (const auto& m : inner[n]) {
      indeg[m]++;
    }
  }

  // Kahn, picking the LOWEST BAND first (outermost), then declaration
  // position - so ties break the same way in every port.
  std::vector<std::string> ready;
  for (const auto& n : names) {
    if (0 == indeg[n]) {
      ready.push_back(n);
    }
  }

  std::vector<Ordered> out;
  while (!ready.empty()) {
    std::sort(ready.begin(), ready.end(),
              [&band, &pos](const std::string& a, const std::string& b) {
                if (band[a] != band[b]) {
                  return band[a] < band[b];
                }
                return pos[a] < pos[b];
              });
    std::string n = ready.front();
    ready.erase(ready.begin());

    Ordered row;
    row.name = n;
    row.band = band[n];
    row.entry = merged.get(n);
    out.push_back(row);

    for (const auto& m : inner[n]) {
      if (0 == --indeg[m]) {
        ready.push_back(m);
      }
    }
  }

  if (out.size() != names.size()) {
    std::vector<std::string> stuck;
    for (const auto& n : names) {
      bool emitted = false;
      for (const auto& row : out) {
        if (row.name == n) {
          emitted = true;
          break;
        }
      }
      if (!emitted) {
        stuck.push_back(n);
      }
    }
    std::sort(stuck.begin(), stuck.end());
    throw StationError("station_feature_order",
                       "feature ordering constraints form a cycle among [" +
                           join_strings(stuck, ", ") + "]");
  }

  return out;
}

// Station's own position is PINNED and not orderable (design 8.4): an
// order that moves `station` away from immediately-outside-the-base is
// REJECTED, not honoured.
//
// The pin is INNERMOST, and the spelling matters. A chain composes with
// the FIRST binding outermost, so a pin written in sort terms -
// "station first" - would place every other wrapper between the adapter
// and the base: the exact inversion of the invariant, and one that
// would leave station's wire-truth events observing the wrong boundary
// while still looking ordered.
inline void check_pin(const std::vector<Ordered>& ordered) {
  int at = -1;
  int base = -1;
  for (size_t i = 0; i < ordered.size(); i++) {
    if (-1 == at && "station" == ordered[i].name) {
      at = static_cast<int>(i);
    }
    if (-1 == base && "test" == ordered[i].name) {
      base = static_cast<int>(i);
    }
  }
  if (-1 == at) {
    return;
  }
  int want = -1 == base ? static_cast<int>(ordered.size()) - 1 : base - 1;
  if (at != want) {
    throw StationError("station_feature_order",
                       "an ordering would move `station` away from immediately "
                       "outside the base transport; its position is pinned "
                       "innermost and is not orderable (design 8.4)");
  }
}

// Compose the ordered rows into the ARRAY FORM the generated
// constructor already accepts. Reserved keys are not options and are
// never passed through to the SDK's own option map.
inline Jval compose_features(const std::vector<Ordered>& ordered) {
  Jval out = Jval::list();
  for (const auto& row : ordered) {
    Jval entry = Jval::map();
    entry.set("name", Jval::str(row.name));
    entry.set("active", Jval::boolean(true));
    if (row.entry.ismap()) {
      for (const auto& kv : row.entry.mval) {
        const auto& reserved = reserved_keys();
        if (std::find(reserved.begin(), reserved.end(), kv.first) != reserved.end()) {
          continue;
        }
        entry.set(kv.first, kv.second);
      }
    }
    out.push(entry);
  }
  return out;
}

// The FEATURE kindof of design 8.5 - "map"/"number" where the shape
// kindof says "object"/"integer". TWO DIFFERENT FUNCTIONS, and
// unifying them would make one of the two sets of messages wrong.
inline std::string feature_kindof(const Jval& v) {
  switch (v.type) {
    case Jval::Type::Absent:
    case Jval::Type::Null:
      return "null";
    case Jval::Type::List:
      return "list";
    case Jval::Type::Num:
      return "number";
    case Jval::Type::Map:
      return "map";
    case Jval::Type::Bool:
      return "boolean";
    case Jval::Type::Str:
      return "string";
  }
  return "null";
}

// One design 8.5 fault. COLLECTED, never thrown - the callers own the
// throw.
struct FeatureFault {
  std::string code;
  std::string feature;
  std::string key;
  std::string message;
};

// Check a merged feature map against the SDK'S OWN DECLARATION.
//
// The schema arrives with the FACTORY rather than with a live client
// (design 6.2), so this needs no construction and no network - which is
// what lets check() run it for every instance in CI.
//
// Derived from the descriptor, NEVER hand-written, so it cannot drift:
// when a feature gains an option, the next regeneration teaches station
// about it with no station change.
//
// SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED
// ONLY, and that limit is real and deliberate: an empty list default
// says nothing reliable about its element type and a nested map default
// says nothing about its value shapes.
inline std::vector<FeatureFault> check_features(const Jval& merged,
                                                const Jval& descriptor) {
  std::vector<FeatureFault> faults;

  std::map<std::string, Jval> byname;
  std::vector<std::string> declared;
  Jval features = descriptor.get("features");
  if (features.islist()) {
    for (const auto& row : features.lval) {
      std::string name = scalar_str(row.get("name"));
      if (0 == byname.count(name)) {
        declared.push_back(name);
      }
      byname[name] = row;
    }
  }
  std::sort(declared.begin(), declared.end());

  for (const auto& name : sorted_keys_of(merged)) {
    auto found = byname.find(name);
    if (byname.end() == found) {
      FeatureFault fault;
      fault.code = "station_feature_unknown";
      fault.feature = name;
      fault.message = "the SDK has no feature \"" + name + "\"; it declares [" +
                      join_strings(declared, ", ") + "]";
      faults.push_back(fault);
      continue;
    }

    Jval entry = merged.get(name);
    if (!entry.ismap()) {
      continue;
    }
    Jval defaults = found->second.get("options");
    if (!defaults.ismap()) {
      defaults = Jval::map();
    }
    const std::vector<std::string> defaultkeys = sorted_keys_of(defaults);

    for (const auto& key : sorted_keys_of(entry)) {
      const auto& reserved = reserved_keys();
      if (std::find(reserved.begin(), reserved.end(), key) != reserved.end()) {
        continue;
      }

      if (!defaults.has(key)) {
        // THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is accepted
        // and silently ignored today, because the SDK's own feature
        // spec is `$OPEN` per feature so the SDK cannot catch it and
        // nothing else looks.
        FeatureFault fault;
        fault.code = "station_feature_option";
        fault.feature = name;
        fault.key = key;
        fault.message = "feature \"" + name + "\" declares no option \"" + key +
                        "\"; it declares [" + join_strings(defaultkeys, ", ") + "]";
        faults.push_back(fault);
        continue;
      }

      std::string want = feature_kindof(defaults.get(key));
      std::string got = feature_kindof(entry.get(key));
      if (want != got) {
        FeatureFault fault;
        fault.code = "station_feature_option";
        fault.feature = name;
        fault.key = key;
        fault.message = "feature \"" + name + "\" option \"" + key + "\" expects " +
                        want + ", but found " + got + ": " +
                        canonical_serialize(entry.get(key));
        faults.push_back(fault);
      }
    }
  }

  return faults;
}

// The joined messages of a fault list, for the one error a caller
// raises from them.
inline std::string fault_messages(const std::vector<FeatureFault>& faults) {
  std::vector<std::string> parts;
  for (const auto& fault : faults) {
    parts.push_back(fault.message);
  }
  return join_strings(parts, "; ");
}

// ---------------------------------------------------------------------
// Profiles (design station.md 3.5): station.json from cwd upward to the
// repo root, then ~/.voxgig/station.json; base 'default' + selected
// overlay, deep-merge per plugin EXCEPT secrets.providers which
// replaces wholesale (chain order decides which store wins - a
// positional merge would be actively dangerous).
// ---------------------------------------------------------------------

inline std::string find_config_file(const std::string& from = "") {
  namespace fs = std::filesystem;
  std::error_code ec;
  fs::path dir = from.empty() ? fs::current_path(ec) : fs::path(from);
  dir = fs::absolute(dir, ec);
  for (;;) {
    fs::path candidate = dir / "station.json";
    if (fs::exists(candidate, ec)) {
      return candidate.string();
    }
    bool at_repo_root = fs::exists(dir / ".git", ec);
    fs::path parent = dir.parent_path();
    if (at_repo_root || parent == dir || parent.empty()) {
      break;
    }
    dir = parent;
  }
  const char* home = std::getenv("HOME");
  if (nullptr != home) {
    fs::path candidate = fs::path(home) / ".voxgig" / "station.json";
    if (fs::exists(candidate, ec)) {
      return candidate.string();
    }
  }
  return "";
}

// The parsed station.json, or absent when none is found.
inline Jval load_config(const std::string& from = "") {
  std::string file = find_config_file(from);
  if (file.empty()) {
    return Jval::absent();
  }
  std::ifstream handle(file);
  std::stringstream buffer;
  buffer << handle.rdbuf();
  return parse_json(buffer.str());
}

// Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
// else 'default' (design station.md 3.5 - open() opts outrank env vars).
inline std::string select_profile(const std::string& opt_profile = "") {
  if (!opt_profile.empty()) {
    return opt_profile;
  }
  const char* env = std::getenv("VOXGIG_STATION_PROFILE");
  if (nullptr != env && '\0' != env[0]) {
    return env;
  }
  return "default";
}

struct ResolvedProfile {
  std::string name;
  Jval providers = Jval::list();  // sekreto ProviderSpec list, verbatim
  // The api-level defaults in effect for this profile, keyed by api
  // slug. A REPORT, not an input to the instance merge below - collapsing
  // each namespace first and composing at the end is the exact algorithm
  // 3.3 forbids.
  Jval api = Jval::map();
  // Resolved instances, keyed by REF (`api$tag`, or a bare `api` for the
  // untagged one). An api block declares no instance of its own (3.1),
  // so it never creates an entry here.
  Jval sdk = Jval::map();
};

// The api half of a ref is the substring before the first `$`, and an
// untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
// point: under the old free-form identity which api an instance used was
// itself a merged value, so a port that got the phasing wrong silently
// picked another api's defaults.
inline std::string refapi(const std::string& ref) {
  std::string::size_type at = ref.find('$');
  return std::string::npos == at ? ref : ref.substr(0, at);
}

// Shallow merge, per key, left to right - each source over the one
// before it. An overlay's `policy` REPLACES the base's entirely rather
// than merging `hosts` into it; an allowlist that widens because two
// precedence levels merged is the failure this rule prevents.
inline void merge_into(Jval& out, const Jval& src) {
  if (!src.ismap()) {
    return;
  }
  for (const auto& kv : src.mval) {
    out.set(kv.first, kv.second);
  }
}

inline std::vector<std::string> merged_keys(const Jval& a, const Jval& b) {
  std::set<std::string> keys;
  for (const Jval* m : {&a, &b}) {
    if (m->ismap()) {
      for (const auto& kv : m->mval) {
        keys.insert(kv.first);
      }
    }
  }
  return std::vector<std::string>(keys.begin(), keys.end());
}

// A configured secret name sekreto would reject is caught at profile
// load, not first request (14 station_secret_name) - and then the
// DERIVED names are checked for uniqueness, because envtoken is LOSSY.
//
// It collapses any run of non-alphanumerics to `_`, so `stripe$test` and
// an untagged instance of a `stripe-test` api both derive
// `stripe_test.apikey` and would silently share one credential.
//
// Two instances that EXPLICITLY name one secret are not a collision -
// that is the shared-key case the api-level `secret` exists for.
inline void checksecrets(const Jval& sdk, const std::string& profile_name) {
  for (const auto& entry : sdk.mval) {
    Jval namev = entry.second.get("secret");
    if (!namev.isnone() && !namev.isabsent()) {
      if (!namev.isstr() || !validname(namev.sval)) {
        throw StationError("station_secret_name",
                           "profile \"" + profile_name + "\" sdk \"" + entry.first +
                               "\": secret name rejected by sekreto: " +
                               canonical_serialize(namev));
      }
    }
  }

  std::map<std::string, std::pair<std::string, bool>> seen;
  for (const auto& entry : sdk.mval) {
    Jval namev = entry.second.get("secret");
    bool derived = !namev.isstr() || namev.sval.empty();
    std::string name = derived ? secretname_default(entry.first) : namev.sval;

    auto found = seen.find(name);
    if (seen.end() != found && (derived || found->second.second)) {
      throw StationError(
          "station_secret_collision",
          "profile \"" + profile_name + "\": instances \"" + found->second.first +
              "\" and \"" + entry.first + "\" both resolve to secret name \"" + name +
              "\", so they would share one credential; name it explicitly on "
              "each, or at the api level to share it deliberately (5.1)");
    }
    if (seen.end() == found) {
      seen[name] = std::make_pair(entry.first, derived);
    }
  }
}

// Merge the base profile ('default') with the selected overlay.
//
// Design 3.3's total order for the two block levels, lowest first:
//
//   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
//
// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
// LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
// namespace, then put instance over api" - that lets every instance
// value beat every api value, so a production `api.stripe.policy` would
// fail to override a default profile's `sdk.stripe$test.policy`,
// silently keeping the wider allowlist in production.
inline ResolvedProfile resolve_profile(const Jval& config, const std::string& profile_name) {
  Jval profiles = config.get("profiles");
  Jval base = profiles.get("default");
  Jval overlay = "default" == profile_name ? Jval::absent() : profiles.get(profile_name);

  // secrets.providers REPLACES wholesale; the default chain is env-only.
  Jval providers = overlay.get("secrets").get("providers");
  if (providers.isnone()) {
    providers = base.get("secrets").get("providers");
  }
  if (providers.isnone()) {
    providers = Jval::list();
    Jval env = Jval::map();
    env.set("kind", Jval::str("env"));
    providers.push(env);
  }

  Jval base_api = base.get("api");
  Jval over_api = overlay.get("api");
  Jval base_sdk = base.get("sdk");
  Jval over_sdk = overlay.get("sdk");

  Jval api = Jval::map();
  for (const std::string& slug : merged_keys(base_api, over_api)) {
    Jval merged = Jval::map();
    merge_into(merged, base_api.get(slug));
    merge_into(merged, over_api.get(slug));
    api.set(slug, merged);
  }

  Jval sdk = Jval::map();
  for (const std::string& ref : merged_keys(base_sdk, over_sdk)) {
    std::string a = refapi(ref);
    Jval merged = Jval::map();
    merge_into(merged, base_api.get(a));
    merge_into(merged, base_sdk.get(ref));
    merge_into(merged, over_api.get(a));
    merge_into(merged, over_sdk.get(ref));

    // Defaults are applied ONCE, to the fully merged instance. Had the
    // overlay block carried a synthesized `active` into the merge, a
    // one-key environment override would silently re-enable an
    // integration the base declared inactive.
    if (merged.get("active").isabsent()) {
      merged.set("active", Jval::boolean(true));
    }
    if (merged.get("feature").isabsent()) {
      merged.set("feature", Jval::map());
    }

    sdk.set(ref, merged);
  }

  checksecrets(sdk, profile_name);

  ResolvedProfile out;
  out.name = profile_name;
  out.providers = providers;
  out.api = api;
  out.sdk = sdk;
  return out;
}

// ---------------------------------------------------------------------
// The instance ref grammar (design station.md 6.1), pinned by the
// `instanceref` corpus section.
//
//   REF_NAME = ^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$   length 1..1024
//   REF_TAG  = ^[a-zA-Z0-9.~_-]+$  OR empty    length 0..1024
//   split on the FIRST `$`, so "a$b$c" is a good name with a bad tag
//
// A tag MAY start with a digit, because auto-tagging assigns integer
// tags, and admits neither `@` nor `/`.
// ---------------------------------------------------------------------

inline constexpr size_t REF_MAX = 1024;

inline bool check_instance_name(const std::string& name) {
  if (name.empty() || REF_MAX < name.size()) {
    return false;
  }
  unsigned char first = static_cast<unsigned char>(name[0]);
  if (!(std::isalpha(first) || '@' == first)) {
    return false;
  }
  for (size_t i = 1; i < name.size(); i++) {
    unsigned char c = static_cast<unsigned char>(name[i]);
    if (std::isalnum(c) || '.' == c || '~' == c || '_' == c || '-' == c || '/' == c) {
      continue;
    }
    return false;
  }
  return true;
}

inline bool check_instance_tag(const std::string& tag) {
  // The empty tag is an ordinary tag: the single-instance case writes
  // no tag and never learns tags exist.
  if (tag.empty()) {
    return true;
  }
  if (REF_MAX < tag.size()) {
    return false;
  }
  for (unsigned char c : tag) {
    if (std::isalnum(c) || '.' == c || '~' == c || '_' == c || '-' == c) {
      continue;
    }
    return false;
  }
  return true;
}

// Validate a ref and return its CANONICAL spelling: a trailing `$` (an
// empty tag) is never kept, so `stripe$` and `stripe` are ONE registry
// key rather than two.
inline std::string check_ref(const std::string& ref) {
  std::string::size_type cut = ref.find('$');
  std::string name = refapi(ref);
  std::string tag = std::string::npos == cut ? "" : ref.substr(cut + 1);

  if (!check_instance_name(name)) {
    throw StationError("station_instance_api",
                       "invalid instance name \"" + name + "\" in ref \"" + ref +
                           "\": a name starts with a letter or `@` and uses "
                           "`[a-zA-Z0-9.~_-/]`, max 1024 (design 6.1)");
  }
  if (!check_instance_tag(tag)) {
    throw StationError("station_instance_api",
                       "invalid instance tag \"" + tag + "\" in ref \"" + ref +
                           "\": a tag uses `[a-zA-Z0-9.~_-]`, max 1024 (design 6.1)");
  }
  return tag.empty() ? name : ref;
}

// `as` is a TAG, not a free name: a ref whose name half is another api
// is refused rather than quietly denoting some other definition.
inline void check_api(const std::string& api, const std::string& ref) {
  std::string named = refapi(ref);
  if (named == api) {
    return;
  }
  throw StationError("station_instance_api",
                     "instance \"" + ref + "\" names api \"" + named +
                         "\", but the SDK passed is api \"" + api +
                         "\"; `as` is a tag, not a free name (design 6.1)");
}

// Design 6.1's rule. `instance` wins over `as`; a bare call returns the
// validated api slug; a `$`-LESS `as` IS ALWAYS A TAG and yields
// api+"$"+as; a `$`-bearing value is a full ref validated against the
// api.
//
// The `$`-less branch has NO EXCEPTION for "the tag happens to equal
// the api": design 6.1 says twice and emphatically that `as` is a tag
// rather than a free name, and a rule with no exceptions is the one
// that ports the same way sixteen times. Someone who wants the untagged
// instance passes no `as` at all.
inline std::string instance_ref(const std::string& api, const Jval& fopts) {
  Jval explicitref = fopts.get("instance");
  if (explicitref.isstr() && !explicitref.sval.empty()) {
    check_api(api, explicitref.sval);
    return check_ref(explicitref.sval);
  }

  Jval as = fopts.get("as");
  if (!as.isstr() || as.sval.empty()) {
    // The bare fallback is the SLUG - a name, never a ref: a `$` in it
    // is an invalid name, not an implicit tag.
    if (check_instance_name(api)) {
      return api;
    }
    throw StationError("station_instance_api",
                       "invalid instance name \"" + api +
                           "\": a name starts with a letter or `@` and uses "
                           "`[a-zA-Z0-9.~_-/]`, max 1024 (design 6.1)");
  }

  if (std::string::npos == as.sval.find('$')) {
    return check_ref(api + "$" + as.sval);
  }
  check_api(api, as.sval);
  return check_ref(as.sval);
}

// ---------------------------------------------------------------------
// `package`: the validator this port keeps, and the loader it does not
// (design station.md 6.3, and the non-loader divergence).
// ---------------------------------------------------------------------

// Only MODULE NAMES, resolved by the host language's ordinary
// resolution from the application root - never a filesystem path, never
// a URL, never anything relative.
//
// THE SEGMENT CHECK IS NOT OPTIONAL AND IS NOT IMPLIED BY THE PREFIX
// CHECKS: "pkg/../../escape" starts with neither `.` nor `/`, so a
// first-character check passes it, and a host that resolved it would
// reach application-local code from OUTSIDE the named dependency.
//
// C++ HAS NO LOADER (see the divergence note on resolve_factory), so
// this is a pure validator here: it rejects a malformed `package` value
// with the same station_sdk_load message every loader port raises, and
// nothing in this port ever imports anything. Kept because it is pure
// and cheap and because a config shared with a loader port should fail
// the same way in both.
inline std::string check_package(const std::string& api, const std::string& pkg) {
  bool bad = pkg.empty();
  if (!bad) {
    bad = '.' == pkg[0] || '/' == pkg[0] || '~' == pkg[0];
  }
  if (!bad) {
    bad = std::string::npos != pkg.find("://") || std::string::npos != pkg.find('\\');
  }
  if (!bad) {
    size_t start = 0;
    for (size_t i = 0; i <= pkg.size(); i++) {
      if (i == pkg.size() || '/' == pkg[i]) {
        std::string seg = pkg.substr(start, i - start);
        if ("." == seg || ".." == seg) {
          bad = true;
          break;
        }
        start = i + 1;
      }
    }
  }
  if (bad) {
    throw StationError("station_sdk_load",
                       "api \"" + api +
                           "\": `package` must be a module name resolved from the "
                           "application root, not a path or URL: " +
                           canonical_serialize(Jval::str(pkg)));
  }
  return pkg;
}

// ---------------------------------------------------------------------
// The factory table (design station.md 6.2)
//
// A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
// callable. Station composes the ordered feature array FOR the
// constructor, so it needs the transport roles and the feature option
// schemas BEFORE construction - but the adapter builds and registers
// its descriptor DURING construction, so nothing would be known in
// time. The generated package emits its config as a module-level
// constant, which exists as soon as it is linked; station normalizes
// the descriptor AT PROVIDE TIME and three things follow: the per-api
// descriptor cache is populated at REGISTRATION rather than on first
// construction, check() can validate every instance's feature config
// WITHOUT constructing anything, and the adapter's registration during
// construction becomes a RECONCILIATION rather than the first sighting.
//
// PROCESS-GLOBAL, and station-independent: it holds no configuration,
// only "here is how to construct this api".
//
// THE C++ DIVERGENCE (design 6.2 path 1, and the loader's absence): of
// the three ways the table gets filled this port offers exactly ONE -
// `provide`, called by the application (or by a generated SDK's own
// registrar) before the first `sdk()`. A header-only library vendored
// into a static C++ SDK has no module-init hook a linker is required to
// run, and C++ has no import-by-name at run time at all. README.md
// states it in full.
// ---------------------------------------------------------------------

// The generated constructor, as station calls it: station-built options
// in, a client out. The client is `shared_ptr<void>` because a station
// library cannot name the generated SDK's type - the same opaque
// identity the binding seam already crosses with. A caller casts:
// `std::static_pointer_cast<TaskpadSDK>(client)`.
using ConstructFn = std::function<std::shared_ptr<void>(const Jval& options)>;

// What a generated package (or an application) hands station.
struct Factory {
  ConstructFn construct;
  Jval config;
};

// One registered api: the factory, plus the descriptor normalized at
// provide time.
struct FactoryEntry {
  std::string api;
  ConstructFn construct;
  Jval config;
  Jval descriptor;
  std::vector<std::string> warnings;
};

namespace detail {

inline std::mutex& factory_mutex() {
  static std::mutex m;
  return m;
}

inline std::map<std::string, std::shared_ptr<FactoryEntry>>& factory_table() {
  static std::map<std::string, std::shared_ptr<FactoryEntry>> table;
  return table;
}

// "The same pair", read literally. The dynamic ports compare object
// identity (`prior.construct === factory.construct`); C++ has no such
// handle - `std::function` is not equality-comparable and a generated
// SDK's config constant may be rebuilt per call - so sameness is the
// same callable TYPE and the same canonical config BYTES. Two
// registrations that differ in either are two factories.
inline bool same_factory(const FactoryEntry& prior, const Factory& incoming) {
  return prior.construct.target_type() == incoming.construct.target_type() &&
         canonical_serialize(prior.config) == canonical_serialize(incoming.config);
}

}  // namespace detail

inline std::shared_ptr<const FactoryEntry> factory_for(const std::string& api) {
  std::lock_guard<std::mutex> lock(detail::factory_mutex());
  auto& table = detail::factory_table();
  auto found = table.find(api);
  return table.end() == found ? nullptr : found->second;
}

// Register an api's { construct, config } pair.
//
// IDEMPOTENT per api: registering the SAME pair twice is a no-op,
// because a generated SDK's own registrar plus an explicit `provide`
// for one api is an ordinary thing for an application to end up with. A
// second registration with a DIFFERENT factory is
// station_factory_conflict - a process has one build of an SDK, and
// picking between two silently is not a thing to do quietly.
inline std::shared_ptr<const FactoryEntry> provide(const std::string& api,
                                                   const Factory& factory) {
  std::lock_guard<std::mutex> lock(detail::factory_mutex());
  auto& table = detail::factory_table();

  auto found = table.find(api);
  if (table.end() != found) {
    if (detail::same_factory(*found->second, factory)) {
      return found->second;
    }
    throw StationError("station_factory_conflict",
                       "two different factories registered for api \"" + api +
                           "\"; a process has one build of an SDK, and picking "
                           "between two silently is not a thing to do quietly");
  }

  // AT PROVIDE TIME, which is the whole point of carrying `config` -
  // and with NO per-instance features, so the shared value holds only
  // api-stable metadata.
  Normalized norm = normalize_descriptor(factory.config, Jval::absent());

  auto entry = std::make_shared<FactoryEntry>();
  entry->api = api;
  entry->construct = factory.construct;
  entry->config = factory.config;
  entry->descriptor = norm.descriptor;
  entry->warnings = norm.warnings;
  table[api] = entry;
  return entry;
}

// The api slugs currently registered, sorted.
inline std::vector<std::string> provided() {
  std::lock_guard<std::mutex> lock(detail::factory_mutex());
  std::vector<std::string> out;
  for (const auto& kv : detail::factory_table()) {
    out.push_back(kv.first);
  }
  std::sort(out.begin(), out.end());
  return out;
}

// Test seam. The table is process-global by design, so a suite that
// registers factories has to be able to put the process back.
inline void reset_factories() {
  std::lock_guard<std::mutex> lock(detail::factory_mutex());
  detail::factory_table().clear();
}

// ---------------------------------------------------------------------
// Events (design station.md 6): a bounded ring buffer plus a live tap
// with serialized callbacks. Events never fail an operation; overflow
// drops oldest and the drop count is visible in status().
// ---------------------------------------------------------------------

inline long long now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

class EventBuffer {
 public:
  explicit EventBuffer(size_t max = 1000) : max_(max) {}

  void emit(const Jval& ev) {
    std::vector<std::function<void(const Jval&)>> taps;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      ring_.push_back(ev);
      if (ring_.size() > max_) {
        ring_.erase(ring_.begin());
        drops_++;
      }
      for (const auto& t : taps_) {
        taps.push_back(t.second);
      }
    }
    // Serialized, and a throwing tap must not fail the operation that
    // emitted the event.
    for (const auto& fn : taps) {
      try {
        fn(ev);
      } catch (...) {
      }
    }
  }

  std::vector<Jval> events() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return ring_;
  }

  // Subscribe; the returned function unsubscribes.
  std::function<void()> tap(const std::function<void(const Jval&)>& fn) {
    std::lock_guard<std::mutex> lock(mutex_);
    long long id = ++tapseq_;
    taps_.emplace_back(id, fn);
    return [this, id]() {
      std::lock_guard<std::mutex> inner(mutex_);
      taps_.erase(std::remove_if(taps_.begin(), taps_.end(),
                                 [id](const auto& t) { return t.first == id; }),
                  taps_.end());
    };
  }

  Jval status() const {
    std::lock_guard<std::mutex> lock(mutex_);
    Jval out = Jval::map();
    out.set("buffered", Jval::num(static_cast<double>(ring_.size())));
    out.set("dropped", Jval::num(static_cast<double>(drops_)));
    return out;
  }

 private:
  mutable std::mutex mutex_;
  std::vector<Jval> ring_;
  size_t max_;
  long long drops_ = 0;
  std::vector<std::pair<long long, std::function<void(const Jval&)>>> taps_;
  long long tapseq_ = 0;
};

// ---------------------------------------------------------------------
// Secrets (design station.md 5): sekreto resolves, station places - and
// with no sekreto C++ port, "resolves" is the process environment only,
// stated honestly (design 2.2). The broker holds resolved values
// privately; the SDK sees only the placeholder.
// ---------------------------------------------------------------------

inline std::string placeholder_for(const std::string& slug) {
  return "[station:" + slug + "]";
}

class SecretBroker {
 public:
  explicit SecretBroker(const Jval& providers) : providers_(providers) {}

  // The provider kinds this env-only broker cannot serve (everything
  // but 'env'), for the one honest warning at open.
  std::vector<std::string> unsupported_kinds() const {
    std::vector<std::string> out;
    if (providers_.islist()) {
      for (const auto& p : providers_.lval) {
        std::string kind = p.ismap() ? p.get("kind").str_or("?") : "?";
        if ("env" != kind && std::find(out.begin(), out.end(), kind) == out.end()) {
          out.push_back(kind);
        }
      }
    }
    std::sort(out.begin(), out.end());
    return out;
  }

  void hoist(const std::string& slug, const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex_);
    overrides_[slug] = value;
    held_.push_back(value);
  }

  // Resolve the value for a plugin's secret name. Env-only, and the
  // miss keeps sekreto's meaning (design station.md 5.2): an unset
  // variable is station_secret_no_value; a set-but-empty variable is a
  // present (empty) value, exactly as sekreto's env provider reads it.
  // There is no store that can "fail to answer" here, so
  // station_secret_error is reserved for malformed names.
  std::string value(const std::string& slug, const std::string& name) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto ov = overrides_.find(slug);
      if (ov != overrides_.end()) {
        return ov->second;
      }
      auto cached = cache_.find(slug);
      if (cached != cache_.end()) {
        return cached->second;
      }
    }

    const char* raw = std::getenv(envkey(name).c_str());
    if (nullptr == raw) {
      throw StationError("station_secret_no_value",
                         "no store had \"" + name + "\" for plugin \"" + slug + "\"");
    }
    std::string value(raw);

    std::lock_guard<std::mutex> lock(mutex_);
    cache_[slug] = value;
    held_.push_back(value);
    return value;
  }

  // Exact-value scrub, deliberately WITHOUT sekreto's four-character
  // readability floor (design station.md 7 as revised): on boundaries
  // where the promise is absolute, every held value is scrubbed
  // whatever its length.
  std::string scrub(const std::string& text) const {
    std::string out = text;
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& value : held_) {
      if (value.empty()) {
        continue;
      }
      size_t pos = 0;
      while ((pos = out.find(value, pos)) != std::string::npos) {
        out.replace(pos, value.size(), "[redacted]");
        pos += 10;  // strlen("[redacted]")
      }
    }
    return out;
  }

  // Drop caches so the next resolve asks the environment again
  // (rotation support, design station.md 5.3).
  void refresh() {
    std::lock_guard<std::mutex> lock(mutex_);
    cache_.clear();
  }

 private:
  mutable std::mutex mutex_;
  Jval providers_;
  std::map<std::string, std::string> overrides_;
  std::map<std::string, std::string> cache_;
  std::vector<std::string> held_;
};

// ---------------------------------------------------------------------
// The Station (design D1: the in-process hub, solo mode)
// ---------------------------------------------------------------------

// open() options. `has_config`+`config` stand in for ts's explicit
// undefined-vs-null: has_config=false loads station.json from disk;
// has_config=true uses `config` verbatim (absent/null = no config at
// all, no file lookup).
struct StationOptions {
  std::string profile;         // '' = VOXGIG_STATION_PROFILE, else 'default'
  std::string proxy = "auto";  // 'auto' | 'off' | 'require' | <url> (tier C: never attaches)
  std::string folder;          // config search start ('' = cwd)
  bool has_config = false;
  Jval config;
};

class Station;

namespace detail {
inline std::mutex& ambient_mutex() {
  static std::mutex m;
  return m;
}
inline std::shared_ptr<Station>& ambient_ref() {
  static std::shared_ptr<Station> ambient;
  return ambient;
}
inline std::string& ambient_key_ref() {
  static std::string key;
  return key;
}
inline std::string opts_key(const StationOptions& opts) {
  Jval k = Jval::map();
  k.set("profile", Jval::str(opts.profile));
  k.set("proxy", Jval::str(opts.proxy));
  k.set("folder", Jval::str(opts.folder));
  k.set("has_config", Jval::boolean(opts.has_config));
  k.set("config", opts.config);
  return canonical_serialize(k);
}
inline long long next_corr() {
  static std::atomic<long long> seq{0};
  return ++seq;
}
}  // namespace detail

class Station {
 public:
  // One registered plugin.
  struct PluginEntry {
    std::string slug;
    Jval descriptor;
    std::string rung;  // 'R1' | 'none'
    const void* client = nullptr;
    std::string secretname;
    std::vector<std::string> warnings;
  };

  // What _register hands back to the binding (design station.md 3 item 1).
  struct Reg {
    std::string slug;
    std::string placeholder;
    std::string secretname;
    std::string rung = "none";
    Jval profile_plugin;
  };

  // Ambient instance (design station.md 10.2): open() is the idempotent
  // process-wide singleton; a second open() with conflicting options is
  // an error; a direct `Station st(opts)` stays isolated for tests.
  // open() is non-blocking - solo involves no network.
  static std::shared_ptr<Station> open(const StationOptions& opts = StationOptions()) {
    std::lock_guard<std::mutex> lock(detail::ambient_mutex());
    std::string key = detail::opts_key(opts);
    auto& ambient = detail::ambient_ref();
    if (nullptr != ambient) {
      if (key != detail::ambient_key_ref()) {
        throw StationError("station_open_conflict",
                           "Station::open() was already called with different options");
      }
      return ambient;
    }
    ambient = std::make_shared<Station>(opts);
    detail::ambient_key_ref() = key;
    return ambient;
  }

  // The ambient instance, or null - never creates one. The generated
  // station feature binds through this (design station.md 3.1: binding
  // is never implicit; only open() creates the ambient instance).
  static std::shared_ptr<Station> current() {
    std::lock_guard<std::mutex> lock(detail::ambient_mutex());
    return detail::ambient_ref();
  }

  // Test seam: drop the ambient instance.
  static void reset() {
    std::lock_guard<std::mutex> lock(detail::ambient_mutex());
    detail::ambient_ref().reset();
    detail::ambient_key_ref().clear();
  }

  explicit Station(const StationOptions& opts = StationOptions())
      : opts_(opts),
        profile_(resolve_profile(opts.has_config ? opts.config : load_config(opts.folder),
                                 select_profile(opts.profile))),
        broker_(profile_.providers),
        require_proxy_("require" == opts.proxy) {
    if ("auto" == opts_.proxy) {
      // The probe is deferred with the proxy itself (tier C: no wire
      // client); absence degrades to solo with a single warning event
      // naming the cause (design 14).
      Jval ev = Jval::map();
      ev.set("t", Jval::num(static_cast<double>(now_ms())));
      ev.set("kind", Jval::str("station"));
      Jval meta = Jval::map();
      meta.set("warn", Jval::str("proxy absent (not found); running solo"));
      ev.set("meta", meta);
      emit(ev);
    }

    // Env-only honesty (design station.md 2.2): a chain naming stores
    // this port cannot reach gets said out loud, once, rather than
    // silently resolving from a weaker store than the profile asked for.
    std::vector<std::string> missing = broker_.unsupported_kinds();
    if (!missing.empty()) {
      std::string kinds;
      for (size_t i = 0; i < missing.size(); i++) {
        if (0 < i) kinds += ", ";
        kinds += missing[i];
      }
      Jval ev = Jval::map();
      ev.set("t", Jval::num(static_cast<double>(now_ms())));
      ev.set("kind", Jval::str("station"));
      Jval meta = Jval::map();
      meta.set("warn",
               Jval::str("c++ station is env-only (no sekreto c++ port): provider "
                         "kind(s) [" +
                         kinds +
                         "] are not available; secrets are read from the process "
                         "environment only (design 2.2)"));
      ev.set("meta", meta);
      emit(ev);
    }
  }

  // --- registration (design station.md 3 item 1, called by the binding) ---

  // Is this client already bound here? Same construction, second
  // arrival must no-op (design 10.2 / ts Station._boundEntry).
  bool _bound(const void* client) const {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& entry : registry_) {
      if (entry.second.client == client) {
        return true;
      }
    }
    return false;
  }

  bool _wrapped(const void* utility) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return 0 < wrapped_.count(utility);
  }

  void _mark_wrapped(const void* utility) {
    std::lock_guard<std::mutex> lock(mutex_);
    wrapped_.insert(utility);
  }

  Reg _register(const void* client, const Jval& config, const Jval& active_features,
                const std::string& fsecret) {
    Normalized norm = normalize_descriptor(config, active_features);
    std::string slug = norm.descriptor.get("slug").str_or("");

    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (0 < registry_.count(slug)) {
        throw StationError("station_bound_twice",
                           "plugin \"" + slug +
                               "\" is already registered; binding one client twice is "
                               "an error (10.2)");
      }
    }

    Jval profile_plugin = profile_.sdk.get(slug);

    // Secret name precedence: the feature option (in-code, design
    // station.md 9 config.options.secret) beats the profile, which
    // beats the descriptor default.
    std::string secretname = fsecret;
    if (secretname.empty()) {
      secretname = profile_plugin.get("secret").str_or("");
    }
    if (secretname.empty()) {
      secretname = norm.descriptor.get("auth").get("secretname").str_or("");
    }

    Jval authactive = norm.descriptor.get("auth").get("active");
    bool auth = authactive.isbool() && authactive.bval;

    Reg reg;
    reg.slug = slug;
    reg.rung = auth ? "R1" : "none";
    reg.placeholder = auth ? placeholder_for(slug) : "";
    reg.secretname = auth ? secretname : "";
    reg.profile_plugin = profile_plugin;

    PluginEntry entry;
    entry.slug = slug;
    entry.descriptor = norm.descriptor;
    entry.rung = reg.rung;
    entry.client = client;
    entry.secretname = secretname;
    entry.warnings = norm.warnings;

    {
      std::lock_guard<std::mutex> lock(mutex_);
      registry_[slug] = entry;
      order_.push_back(slug);
    }

    for (const auto& w : norm.warnings) {
      emit_warn(slug, w);
    }

    Jval ev = Jval::map();
    ev.set("t", Jval::num(static_cast<double>(now_ms())));
    ev.set("kind", Jval::str("construct"));
    ev.set("plugin", Jval::str(slug));
    Jval meta = Jval::map();
    meta.set("name", norm.descriptor.get("name"));
    meta.set("version", norm.descriptor.get("version"));
    meta.set("rung", Jval::str(reg.rung));
    ev.set("meta", meta);
    emit(ev);

    return reg;
  }

  void _hoist(const std::string& slug, const std::string& value) {
    broker_.hoist(slug, value);
    emit_warn(slug,
              "a resident credential was hoisted into the broker and replaced by "
              "the placeholder; prefer configuring the secret name and letting "
              "the environment resolve it");
  }

  // The resolved secret value for a registered plugin (throws
  // StationError on a miss - design station.md 5.2).
  std::string _secret_value(const std::string& slug) {
    std::string secretname;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = registry_.find(slug);
      if (it == registry_.end()) {
        throw StationError("station_no_plugin", "unknown plugin \"" + slug + "\"");
      }
      secretname = it->second.secretname;
    }
    return broker_.value(slug, secretname);
  }

  // --- the query/observe surface (design station.md 3.2, 6) ---

  Jval plugins() const {
    std::lock_guard<std::mutex> lock(mutex_);
    Jval out = Jval::list();
    for (const auto& slug : order_) {
      const auto& entry = registry_.at(slug);
      Jval p = Jval::map();
      p.set("slug", Jval::str(entry.slug));
      p.set("descriptor", entry.descriptor);
      p.set("rung", Jval::str(entry.rung));
      Jval warnings = Jval::list();
      for (const auto& w : entry.warnings) {
        warnings.push(Jval::str(w));
      }
      p.set("warnings", warnings);
      out.push(p);
    }
    return out;
  }

  Jval descriptor_of(const std::string& slug) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = registry_.find(slug);
    if (it == registry_.end()) {
      std::string known;
      for (size_t i = 0; i < order_.size(); i++) {
        if (0 < i) known += ", ";
        known += order_[i];
      }
      throw StationError("station_no_plugin",
                         "unknown plugin \"" + slug + "\"; known: [" + known + "]");
    }
    return it->second.descriptor;
  }

  std::string canonical_descriptor(const std::string& slug) const {
    return canonical_serialize(descriptor_of(slug));
  }

  std::vector<Jval> events() const { return buffer_.events(); }

  std::function<void()> tap(const std::function<void(const Jval&)>& fn) {
    return buffer_.tap(fn);
  }

  Jval status() const {
    Jval out = Jval::map();
    out.set("mode", Jval::str("solo"));
    out.set("profile", Jval::str(profile_.name));
    Jval plugins_out = Jval::list();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (const auto& slug : order_) {
        const auto& entry = registry_.at(slug);
        Jval p = Jval::map();
        p.set("slug", Jval::str(entry.slug));
        p.set("rung", Jval::str(entry.rung));
        plugins_out.push(p);
      }
    }
    out.set("plugins", plugins_out);
    out.set("events", buffer_.status());
    // Env-only, stated where an operator will read it (design 2.2).
    out.set("secrets", Jval::str("env-only"));
    return out;
  }

  std::string redact(const std::string& text) const { return broker_.scrub(text); }

  void refresh_secrets() { broker_.refresh(); }

  const ResolvedProfile& profile() const { return profile_; }
  bool requires_proxy() const { return require_proxy_; }

  // close(): flush (solo: nothing in flight), then warn on profile
  // plugin keys that matched no registered plugin - a typo'd key
  // silently configuring nothing is the worst outcome for a
  // secrets-and-policy file (design station.md 11).
  void close() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) {
        return;
      }
      closed_ = true;
    }
    std::vector<std::string> keys;
    for (const auto& entry : profile_.sdk.mval) {
      keys.push_back(entry.first);
    }
    std::sort(keys.begin(), keys.end());
    for (const auto& slug : keys) {
      bool registered;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        registered = 0 < registry_.count(slug);
      }
      if (!registered) {
        Jval ev = Jval::map();
        ev.set("t", Jval::num(static_cast<double>(now_ms())));
        ev.set("kind", Jval::str("station"));
        Jval meta = Jval::map();
        meta.set("warn", Jval::str("profile plugin key \"" + slug +
                                   "\" matched no registered plugin"));
        ev.set("meta", meta);
        emit(ev);
      }
    }
    {
      std::lock_guard<std::mutex> lock(detail::ambient_mutex());
      if (detail::ambient_ref().get() == this) {
        detail::ambient_ref().reset();
        detail::ambient_key_ref().clear();
      }
    }
  }

  bool closed() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
  }

  // --- event emitters (shared by core and the SDK seam) ---

  void emit(const Jval& ev) { buffer_.emit(ev); }

  void emit_warn(const std::string& slug, const std::string& warn) {
    Jval ev = Jval::map();
    ev.set("t", Jval::num(static_cast<double>(now_ms())));
    ev.set("kind", Jval::str("station"));
    if (!slug.empty()) {
      ev.set("plugin", Jval::str(slug));
    }
    Jval meta = Jval::map();
    meta.set("warn", Jval::str(warn));
    ev.set("meta", meta);
    emit(ev);
  }

  // ( host-with-port, hostname, path ) from a URL, stdlib only. Mirrors
  // ts URL semantics: host keeps a non-default port, hostname strips
  // it, an empty path reads as '/'.
  static void parse_url(const std::string& url, std::string& host, std::string& hostname,
                        std::string& path) {
    host.clear();
    hostname.clear();
    path = url;
    size_t sep = url.find("://");
    if (std::string::npos == sep || 0 == sep) {
      return;
    }
    std::string scheme = url.substr(0, sep);
    for (auto& c : scheme) {
      c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    size_t astart = sep + 3;
    size_t aend = url.find_first_of("/?#", astart);
    std::string authority =
        url.substr(astart, (std::string::npos == aend ? url.size() : aend) - astart);
    std::string rest = std::string::npos == aend ? "" : url.substr(aend);
    size_t q = rest.find_first_of("?#");
    path = std::string::npos == q ? rest : rest.substr(0, q);
    if (path.empty() || '?' == path[0] || '#' == path[0]) {
      path = "/";
    }
    size_t at = authority.find('@');
    if (std::string::npos != at) {
      authority = authority.substr(at + 1);
    }
    hostname = authority;
    std::string port;
    size_t colon = authority.rfind(':');
    if (std::string::npos != colon) {
      std::string cand = authority.substr(colon + 1);
      bool digits = !cand.empty();
      for (unsigned char c : cand) {
        if (!std::isdigit(c)) {
          digits = false;
          break;
        }
      }
      if (digits) {
        hostname = authority.substr(0, colon);
        port = cand;
      }
    }
    std::string dflt = "http" == scheme ? "80" : ("https" == scheme ? "443" : "");
    host = hostname;
    if (!port.empty() && port != dflt) {
      host = hostname + ":" + port;
    }
  }

  void emit_http(const std::string& slug, const std::string& corr, const std::string& fullurl,
                 const std::string& method, int status, long long started, long long bytes) {
    std::string host, hostname, path;
    parse_url(fullurl, host, hostname, path);
    Jval ev = Jval::map();
    ev.set("t", Jval::num(static_cast<double>(started)));
    ev.set("kind", Jval::str("http"));
    ev.set("plugin", Jval::str(slug));
    if (!corr.empty()) {
      ev.set("corr", Jval::str(corr));
    }
    Jval http = Jval::map();
    http.set("method", Jval::str(method.empty() ? "GET" : method));
    http.set("host", Jval::str(host));
    http.set("path", Jval::str(path));
    http.set("status", Jval::num(static_cast<double>(status)));
    http.set("durationMs", Jval::num(static_cast<double>(now_ms() - started)));
    http.set("bytes", Jval::num(static_cast<double>(bytes)));
    ev.set("http", http);
    emit(ev);
  }

  void emit_err(const std::string& slug, const std::string& corr, const std::string& code,
                const std::string& message) {
    Jval ev = Jval::map();
    ev.set("t", Jval::num(static_cast<double>(now_ms())));
    ev.set("kind", Jval::str("error"));
    ev.set("plugin", Jval::str(slug));
    if (!corr.empty()) {
      ev.set("corr", Jval::str(corr));
    }
    Jval err = Jval::map();
    if (!code.empty()) {
      err.set("code", Jval::str(code));
    }
    // The scrub keeps an upstream echo of a credential out of the event
    // stream (design station.md 7 as revised: exact-value, no floor).
    err.set("message", Jval::str(redact(message)));
    ev.set("err", err);
    emit(ev);
  }

  void emit_op(const std::string& slug, const std::string& corr, const std::string& entity,
               const std::string& op, const std::string& outcome, long long duration_ms) {
    Jval ev = Jval::map();
    ev.set("t", Jval::num(static_cast<double>(now_ms())));
    ev.set("kind", Jval::str("op"));
    ev.set("plugin", Jval::str(slug));
    if (!corr.empty()) {
      ev.set("corr", Jval::str(corr));
    }
    Jval opv = Jval::map();
    opv.set("entity", Jval::str(entity));
    opv.set("op", Jval::str(op));
    opv.set("outcome", Jval::str(outcome));
    opv.set("durationMs", Jval::num(static_cast<double>(duration_ms)));
    ev.set("op", opv);
    emit(ev);
  }

#if defined(SDK_CORE_TYPES_HPP)
  // -------------------------------------------------------------------
  // The SDK seam (compiled only inside a generated C++ SDK; see the
  // header comment). All logic the generated StationFeature calls lives
  // here, not in the adapter - design station.md 2, "thin by design".
  // -------------------------------------------------------------------

  // Inverted binding (design station.md 3.1): build the plain options
  // map the generated constructor already accepts - the activation
  // entry plus the caller's own opts carried as data (`calleropts`) for
  // the design 3.5 base-precedence rule. The binding itself is to the
  // AMBIENT station (see the header comment's design delta).
  ::sdk::Value options(const ::sdk::Value& extra = ::sdk::Value()) const {
    ::sdk::Value out = extra.is_map() ? ::sdk::Struct::clone(extra) : ::sdk::vmap();
    ::sdk::Value fmap = ::sdk::Helpers::toMapAny(::sdk::getp(out, "feature"));
    if (!fmap.is_map()) {
      fmap = ::sdk::vmap();
      ::sdk::map_put(out, "feature", fmap);
    }
    ::sdk::Value entry = ::sdk::Helpers::toMapAny(::sdk::getp(fmap, "station"));
    if (!entry.is_map()) {
      entry = ::sdk::vmap();
      ::sdk::map_put(fmap, "station", entry);
    }
    ::sdk::map_put(entry, "active", ::sdk::Value(true));
    ::sdk::map_put(entry, "calleropts",
                   extra.is_map() ? ::sdk::Struct::clone(extra) : ::sdk::vmap());
    return out;
  }

  // The per-op correlation slot, id-guarded so direct()/graphql()
  // traffic (which skips the hook pipeline but not the transport) never
  // reads a stale correlation from a previous operation.
  static std::string _corr_of(const ::sdk::CtxPtr& ctx) {
    if (!ctx || !ctx->shared.is_map()) {
      return "";
    }
    ::sdk::Value st = ::sdk::Helpers::toMapAny(::sdk::getp(ctx->shared, "station$"));
    if (!st.is_map()) {
      return "";
    }
    if (::sdk::as_str(::sdk::getp(st, "id")) != ctx->id) {
      return "";
    }
    return ::sdk::as_str(::sdk::getp(st, "corr"));
  }

  static long long _start_of(const ::sdk::CtxPtr& ctx) {
    if (!ctx || !ctx->shared.is_map()) {
      return 0;
    }
    ::sdk::Value st = ::sdk::Helpers::toMapAny(::sdk::getp(ctx->shared, "station$"));
    if (!st.is_map() || ::sdk::as_str(::sdk::getp(st, "id")) != ctx->id) {
      return 0;
    }
    return ::sdk::as_long(::sdk::getp(st, "start"), 0);
  }

  // The transport middleware (design station.md 3.3, 5.3). `inner` is
  // the transport that was current at init time. Failure follows the
  // C++ SDK convention: thrown SdkErrorPtr - a wrap must catch to
  // observe, then rethrow unchanged.
  ::sdk::Value _transport(
      const std::string& slug,
      const std::function<::sdk::Value(::sdk::CtxPtr, const std::string&,
                                       const ::sdk::Value&)>& inner,
      ::sdk::CtxPtr fctx, const std::string& fullurl, const ::sdk::Value& fetchdef) {
    std::string corr = _corr_of(fctx);

    // Fail-closed means traffic (design 2.1): with no wire client
    // (tier C), `require` can never attach, so every operation fails
    // here - the operation path, never the constructor.
    if (require_proxy_) {
      const char* MSG = "proxy: \"require\" is set and no proxy is attached";
      emit_err(slug, corr, "station_no_proxy", MSG);
      throw fctx->makeError("station_no_proxy", std::string("station_no_proxy: ") + MSG);
    }

    bool has_entry = false;
    std::string rung = "none";
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = registry_.find(slug);
      if (it != registry_.end()) {
        has_entry = true;
        rung = it->second.rung;
      }
    }

    std::string placeholder = placeholder_for(slug);
    bool live = nullptr != fctx->client && "live" == fctx->client->mode;
    Jval profile_plugin = profile_.sdk.get(slug);

    // Egress policy (design station.md 16), solo half: the hosts
    // allowlist is enforced at the seam every request crosses. When a
    // policy is present the fetchdef asks for manual redirects - a 3xx
    // is a response like any other, so a Location off the allowlist
    // cannot pull an automatic credentialed follow-up to an unapproved
    // host (design 8.2's rule at the library seam). NOTE the generated
    // C++ SDK has no built-in live transport; an app-supplied
    // options.system.fetch should honour the redirect slot.
    Jval hosts = profile_plugin.get("policy").get("hosts");
    bool has_hosts = hosts.islist();

    if (has_hosts && live) {
      std::string host, hostname, path;
      parse_url(fullurl, host, hostname, path);
      bool allowed = false;
      for (const auto& h : hosts.lval) {
        if (h.isstr() && h.sval == hostname) {
          allowed = true;
          break;
        }
      }
      if (!allowed) {
        std::string msg = "egress to \"" + hostname +
                          "\" denied by the hosts policy of plugin \"" + slug + "\"";
        emit_err(slug, corr, "station_host_allow", msg);
        throw fctx->makeError("station_host_allow", "station_host_allow: " + msg);
      }
    }

    ::sdk::Value senddef = fetchdef;
    bool copied = false;
    auto ensure_copy = [&]() {
      if (copied) {
        return;
      }
      ::sdk::Value fresh = ::sdk::vmap();
      if (fetchdef.is_map()) {
        for (const auto& kv : *fetchdef.as_map()) {
          ::sdk::map_put(fresh, kv.first, kv.second);
        }
      }
      senddef = fresh;
      copied = true;
    };

    if (has_hosts && live) {
      ensure_copy();
      ::sdk::map_put(senddef, "redirect", ::sdk::Value(std::string("manual")));
    }

    // Injection: at the last boundary, below every recording feature,
    // and never into mock transports (design 3.3) - in test/mock modes
    // the placeholder rides through untouched, so real credentials
    // never enter in-memory mock stores. Copy-on-inject (design 5.3):
    // the generated request machinery shares references -
    // fetchdef.headers IS spec.headers, and ctrl.explain holds the
    // fetchdef - so the fetchdef and its headers map are duplicated
    // before the swap; the object graph reachable from ctx/spec/ctrl
    // holds only the placeholder, ever.
    if (live && has_entry && "R1" == rung) {
      std::string value;
      try {
        value = _secret_value(slug);
      } catch (const StationError& e) {
        emit_err(slug, corr, e.code(), e.message());
        throw fctx->makeError(e.code(), e.what());
      }

      ensure_copy();
      ::sdk::Value headers = ::sdk::vmap();
      ::sdk::Value oldheaders = ::sdk::Helpers::toMapAny(::sdk::getp(senddef, "headers"));
      if (oldheaders.is_map()) {
        for (const auto& kv : *oldheaders.as_map()) {
          ::sdk::Value v = kv.second;
          if (v.is_string() && v.as_string().find(placeholder) != std::string::npos) {
            std::string swapped = v.as_string();
            size_t pos = 0;
            while ((pos = swapped.find(placeholder, pos)) != std::string::npos) {
              swapped.replace(pos, placeholder.size(), value);
              pos += value.size();
            }
            v = ::sdk::Value(swapped);
          }
          ::sdk::map_put(headers, kv.first, v);
        }
      }
      ::sdk::map_put(senddef, "headers", headers);
    }

    std::string method = ::sdk::as_str(::sdk::getp(senddef, "method"), "GET");
    long long started = now_ms();

    ::sdk::Value res;
    try {
      res = inner(fctx, fullurl, senddef);
    } catch (const ::sdk::SdkErrorPtr& err) {
      emit_http(slug, corr, fullurl, method, 0, started, 0);
      emit_err(slug, corr, err ? err->code : "", err ? err->getMessage() : "");
      throw;
    } catch (const std::exception& err) {
      emit_http(slug, corr, fullurl, method, 0, started, 0);
      emit_err(slug, corr, "", err.what());
      throw;
    }

    int status = 0;
    long long bytes = 0;
    if (res.is_map()) {
      ::sdk::Value sv = ::sdk::getp(res, "status");
      if (sv.is_number()) {
        status = static_cast<int>(sv.as_int());
      }
      ::sdk::Value rheaders = ::sdk::Helpers::toMapAny(::sdk::getp(res, "headers"));
      if (rheaders.is_map()) {
        ::sdk::Value cl = ::sdk::getp(rheaders, "content-length");
        if (cl.is_number()) {
          bytes = static_cast<long long>(cl.as_int());
        } else if (cl.is_string()) {
          bytes = std::atoll(cl.as_string().c_str());
        }
      }
    }
    emit_http(slug, corr, fullurl, method, status, started, bytes);

    return res;
  }

  // Op events from the hook bridge (design station.md 3 item 3).
  void _op_event(const std::string& slug, const ::sdk::CtxPtr& ctx,
                 const std::string& outcome) {
    std::string corr = _corr_of(ctx);
    long long start = _start_of(ctx);

    // ctx->op is the SDK's resolved Operation: name + entity, with '_'
    // as the generated C++ SDK's absence sentinel.
    std::string entity = ctx && ctx->op ? ctx->op->entity : "";
    if ("_" == entity) {
      entity = "";
    }
    if (entity.empty() && ctx && nullptr != ctx->entity) {
      entity = ctx->entity->getName();
    }
    std::string opname = ctx && ctx->op ? ctx->op->name : "";
    if ("_" == opname) {
      opname = "";
    }

    emit_op(slug, corr, entity, opname, outcome,
            0 != start ? now_ms() - start : 0);
  }
#endif  // SDK_CORE_TYPES_HPP

 private:
  mutable std::mutex mutex_;
  StationOptions opts_;
  ResolvedProfile profile_;
  SecretBroker broker_;
  EventBuffer buffer_;
  std::map<std::string, PluginEntry> registry_;
  std::vector<std::string> order_;
  std::set<const void*> wrapped_;
  bool require_proxy_ = false;
  bool closed_ = false;
};

#if defined(SDK_CORE_TYPES_HPP)
// ---------------------------------------------------------------------
// The SDK adapter seam (design station.md 3), in ONE place:
// feature_binding() is what the GENERATED station feature delegates to
// from its init() and hook overrides. Registration at init, wrap
// position verified, transport wrapped with copy-on-inject, hooks
// bridged to op events. (The library-carried adapter of connect/adopt
// does not exist for C++ - no extend seam; see the header comment.)
// ---------------------------------------------------------------------

// Convert an SDK Value into the library's own value model at the seam.
// Function-typed values (injectors, json thunks) have no JSON meaning
// and convert to absent, which the serializer drops.
inline Jval to_jval(const ::sdk::Value& v) {
  if (v.is_null()) {
    return Jval::null();
  }
  if (v.is_bool()) {
    return Jval::boolean(v.as_bool());
  }
  if (v.is_number()) {
    return Jval::num(v.as_double());
  }
  if (v.is_string()) {
    return Jval::str(v.as_string());
  }
  if (v.is_list()) {
    Jval out = Jval::list();
    for (const auto& item : *v.as_list()) {
      out.push(to_jval(item));
    }
    return out;
  }
  if (v.is_map()) {
    Jval out = Jval::map();
    for (const auto& kv : *v.as_map()) {
      Jval conv = to_jval(kv.second);
      if (!conv.isabsent()) {
        out.set(kv.first, conv);
      }
    }
    return out;
  }
  return Jval::absent();
}

// The hook bridge handed back to the generated feature (design
// station.md 3 item 3): operation semantics correlated with the HTTP
// events via a per-operation id on the SDK's own ctx (the `station$`
// slot in ctx->shared, id-guarded).
class FeatureBinding {
 public:
  FeatureBinding(std::shared_ptr<Station> station, const std::string& slug)
      : station_(std::move(station)), slug_(slug) {}

  const std::string& slug() const { return slug_; }

  void PrePoint(const ::sdk::CtxPtr& ctx) {
    if (!ctx || !ctx->shared.is_map()) {
      return;
    }
    long long seq = detail::next_corr();
    ::sdk::Value st = ::sdk::vmap();
    ::sdk::map_put(st, "id", ::sdk::Value(ctx->id));
    ::sdk::map_put(st, "corr", ::sdk::Value("c" + std::to_string(seq)));
    ::sdk::map_put(st, "start", ::sdk::Value(static_cast<int64_t>(now_ms())));
    ::sdk::map_put(ctx->shared, "station$", st);
  }

  void PreDone(const ::sdk::CtxPtr& ctx) {
    station_->_op_event(slug_, ctx, result_outcome(ctx));
  }

  void PreUnexpected(const ::sdk::CtxPtr& ctx) {
    station_->_op_event(slug_, ctx, "unexpected");
  }

  static std::string result_outcome(const ::sdk::CtxPtr& ctx) {
    if (!ctx || !ctx->result) {
      return "unknown";
    }
    if (ctx->result->err) {
      return "err";
    }
    if (!ctx->result->ok) {
      return "err";
    }
    return "ok";
  }

 private:
  std::shared_ptr<Station> station_;
  std::string slug_;
};

// Resolve the station this activation binds to: the ambient instance
// (C++ options cannot carry an instance handle - header comment). No
// station open -> null: an activated feature with no opened station is
// an inert no-op that emits nothing and fails nothing (design 3.1).
inline std::shared_ptr<FeatureBinding> feature_binding(const ::sdk::CtxPtr& ctx,
                                                       const ::sdk::Value& fopts) {
  std::shared_ptr<Station> station = Station::current();
  if (nullptr == station || !ctx || nullptr == ctx->client) {
    return nullptr;
  }

  ::sdk::SdkClient* client = ctx->client;

  // Second arrival on one client: the first bind won, this one is
  // inert. See Station::_bound.
  if (station->_bound(client)) {
    return nullptr;
  }

  ::sdk::UtilityPtr utility = ctx->utility;
  ::sdk::Value options = ctx->options;

  // Position guard (design station.md 3.3): the wrap must sit
  // immediately outside the base transport - inside retry/cache/
  // ratelimit/netsim - or its http events stop being wire truth.
  // Position in client->features IS init order, so verify it and fail
  // loudly. One C++-specific tolerance (the lua/rb ports', for the
  // same reason): the generated makeFeature FALLS BACK to an inert
  // BaseFeature for unknown names, so an activated unknown entry adds
  // a stray named "base". A base feature has a no-op init - it can
  // never wrap or record the transport - so strays are excluded from
  // the order check, which keeps the guard's actual meaning: nothing
  // that could wrap sits between the base transport and station.
  std::vector<std::string> names;
  for (const auto& f : client->features) {
    names.push_back(f ? f->getName() : "");
  }
  int self_at = -1;
  int test_at = -1;
  int at = 0;
  for (const auto& name : names) {
    if ("base" == name) {
      continue;
    }
    if (-1 == self_at && "station" == name) {
      self_at = at;
    }
    if (-1 == test_at && "test" == name) {
      test_at = at;
    }
    at++;
  }
  int expected = -1 == test_at ? 0 : test_at + 1;
  if (self_at != expected) {
    std::string joined;
    for (size_t i = 0; i < names.size(); i++) {
      if (0 < i) joined += ", ";
      joined += names[i];
    }
    throw ctx->makeError("station_wrap_order",
                         "station_wrap_order: station must init immediately after "
                         "the base transport; feature order is [" +
                             joined + "]");
  }

  // Registration (design station.md 3 item 1): descriptor from the
  // embedded config, converted at the seam.
  Station::Reg reg;
  try {
    reg = station->_register(
        client, to_jval(ctx->config),
        to_jval(::sdk::Helpers::toMapAny(::sdk::getp(options, "feature"))),
        ::sdk::as_str(::sdk::getp(fopts, "secret")));
  } catch (const StationError& e) {
    throw ctx->makeError(e.code(), e.what());
  }
  std::string slug = reg.slug;

  // Base URL precedence (design station.md 3.5): caller opts (7) beat
  // the profile (4), which beats the SDK's config default (1) already
  // in options.base. calleropts rides the activation entry as data
  // (Station::options() puts it there).
  ::sdk::Value calleropts = ::sdk::Helpers::toMapAny(::sdk::getp(fopts, "calleropts"));
  if (calleropts.is_map()) {
    ::sdk::Value cbase = ::sdk::getp(calleropts, "base");
    Jval pbase = reg.profile_plugin.get("base");
    if (::sdk::is_nullish(cbase) && !pbase.isnone() && !pbase.isabsent()) {
      ::sdk::map_put(options, "base", ::sdk::Value(pbase.str_or("")));
    }
  }

  if ("none" != reg.rung) {
    const std::string& placeholder = reg.placeholder;

    // A real credential already resident in the options is hoisted
    // into the broker and replaced by the placeholder before
    // construction completes (design station.md 3.1) - optionsMap()
    // and prepare() output become placeholder-safe from here on.
    ::sdk::Value resident = ::sdk::getp(options, "apikey");
    if (resident.is_string() && !resident.as_string().empty() &&
        resident.as_string() != placeholder) {
      station->_hoist(slug, resident.as_string());
    }
    ::sdk::map_put(options, "apikey", ::sdk::Value(placeholder));
  }

  // Wrap the transport. Copy-on-inject (design station.md 5.3) happens
  // inside Station::_transport; auth-inactive plugins skip credential
  // planning but the wrap still observes.
  if (station->_wrapped(utility.get())) {
    throw ctx->makeError("station_bound_twice",
                         "station_bound_twice: plugin \"" + slug +
                             "\" already carries a station wrap");
  }
  auto inner = utility->fetcher;
  std::shared_ptr<Station> held = station;
  utility->fetcher = [held, slug, inner](::sdk::CtxPtr fctx, const std::string& fullurl,
                                         const ::sdk::Value& fetchdef) -> ::sdk::Value {
    return held->_transport(slug, inner, fctx, fullurl, fetchdef);
  };
  station->_mark_wrapped(utility.get());

  return std::make_shared<FeatureBinding>(station, slug);
}
#endif  // SDK_CORE_TYPES_HPP

}  // namespace vstation

#endif  // VOXGIG_STATION_HPP
