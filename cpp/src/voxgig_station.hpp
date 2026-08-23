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
  // options.feature map, when given).
  Jval features = Jval::list();
  Jval fdefs = config.get("feature");
  if (fdefs.ismap()) {
    std::vector<std::string> fnames;
    for (const auto& entry : fdefs.mval) fnames.push_back(entry.first);
    std::sort(fnames.begin(), fnames.end());
    for (const auto& fname : fnames) {
      Jval f = Jval::map();
      f.set("name", Jval::str(fname));
      Jval factive = active_features.get(fname).get("active");
      f.set("active", Jval::boolean(factive.isbool() && factive.bval));
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
  Jval plugin = Jval::map();      // slug -> per-plugin profile map
};

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

  // Per-plugin: base then overlay, shallow-merged per plugin key.
  Jval plugin = Jval::map();
  for (const Jval* src : {&base, &overlay}) {
    Jval srcplugin = src->get("plugin");
    if (!srcplugin.ismap()) {
      continue;
    }
    for (const auto& entry : srcplugin.mval) {
      Jval merged = plugin.get(entry.first);
      if (!merged.ismap()) {
        merged = Jval::map();
      }
      if (entry.second.ismap()) {
        for (const auto& kv : entry.second.mval) {
          merged.set(kv.first, kv.second);
        }
      }
      plugin.set(entry.first, merged);
    }
  }

  // A configured secret name sekreto would reject is caught at profile
  // load, not first request (design station.md 14 station_secret_name).
  for (const auto& entry : plugin.mval) {
    Jval namev = entry.second.get("secret");
    if (!namev.isnone() && !namev.isabsent()) {
      if (!namev.isstr() || !validname(namev.sval)) {
        throw StationError("station_secret_name",
                           "profile \"" + profile_name + "\" plugin \"" + entry.first +
                               "\": secret name rejected by sekreto: " +
                               canonical_serialize(namev));
      }
    }
  }

  ResolvedProfile out;
  out.name = profile_name;
  out.providers = providers;
  out.plugin = plugin;
  return out;
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

    Jval profile_plugin = profile_.plugin.get(slug);

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
    for (const auto& entry : profile_.plugin.mval) {
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
    Jval profile_plugin = profile_.plugin.get(slug);

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
