// The descriptor normalizer and canonical serializer (station design 4):
// a generated SDK's embedded config, normalized into descriptor v1 - a
// VIEW over the config, never a second model - plus the one canonical
// byte serialization every port must agree on.
//
// A port of typescript/src/descriptor.ts, which is canonical.

import Foundation

public enum Descriptor {

  /// The ONLY way to build an env-var token in station, mirroring
  /// sdkgen's packageMeta envToken exactly: 'gnarly-pets' ->
  /// 'GNARLY_PETS'. The `secretname` corpus section pins the round-trip
  /// against sekreto's envkey() and sdkgen's envName() - the one place
  /// three grammars meet.
  public static func envToken(_ name: String?) -> String {
    var out = ""
    var pendingSep = false
    for scalar in (name ?? "").uppercased().unicodeScalars {
      let isToken = ("A" <= scalar && scalar <= "Z") || ("0" <= scalar && scalar <= "9")
      if isToken {
        if pendingSep && !out.isEmpty {
          out.append("_")
        }
        pendingSep = false
        out.unicodeScalars.append(scalar)
      } else {
        pendingSep = true
      }
    }
    return out
  }

  /// The default sekreto name for a plugin (design 5.1): envToken(slug)
  /// lowercased, plus '.apikey'. sekreto's envkey() then yields exactly
  /// the env var the SDK's README documents: gnarly_pets.apikey ->
  /// GNARLY_PETS_APIKEY.
  public static func secretnameDefault(_ slug: String) -> String {
    return envToken(slug).lowercased() + ".apikey"
  }

  // Best-effort slug from a camel name, for SDKs whose embedded config
  // predates main.slug (design 4 legacy sentinels). The hyphen caveat is
  // real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT 'voxgig-solardemo'
  // - callers surface a warning event when this path is taken.
  static func legacySlug(_ name: String) -> String {
    return name.lowercased()
  }

  /// Normalize a generated SDK's embedded config into descriptor v1
  /// (design 4). The config is the one every SDK carries (Config.main /
  /// .feature / .options / .entity); the descriptor is a VIEW over it.
  /// Returns the descriptor plus any legacy warnings.
  public static func normalizeDescriptor(
    _ config: Json, _ activeFeatures: Json
  ) -> (descriptor: Json, warnings: [String]) {
    var warnings: [String] = []
    let main = config.get("main")
    let options = config.get("options")

    let name = main.text("name") ?? ""
    var slug = main.text("slug") ?? ""
    if slug.isEmpty {
      slug = legacySlug(name)
      warnings.append(
        "descriptor: legacy config has no main.slug; derived \"" + slug
          + "\" from the camel name - hyphens in the original name are lost")
    }

    let version = jsonText(main.get("version")) ?? "0.0.0"
    let target = jsonText(main.get("target")) ?? "unknown"

    var server: [Json] = []
    if let svr = options.get("server").asMap {
      for key in sortedKeys(svr) {
        server.append(.map([
          "name": .str(key),
          "value": .str(jsonText(svr[key] ?? .null) ?? ""),
        ]))
      }
    }

    let authActive = !options.get("auth").isNull
    let auth: Json = .map([
      "active": .bool(authActive),
      "prefix": .str(authActive ? (options.get("auth").get("prefix").asStr ?? "") : ""),
      "secretname": .str(secretnameDefault(slug)),
    ])

    var entities: [String: Json] = [:]
    if let entdefs = config.get("entity").asMap {
      for ename in sortedKeys(entdefs) {
        let e = entdefs[ename] ?? .null

        var fields: [String: Json] = [:]
        if let fdefs = e.get("fields").asList {
          for f in fdefs {
            guard let fname = f.get("name").asStr else { continue }
            var kind = f.get("kind")
            if kind.isNull {
              kind = f.get("type")
            }
            fields[fname] = .map(["kind": .str(jsonText(kind) ?? "")])
          }
        }

        var ops: [String: Json] = [:]
        if let opdefs = e.get("op").asMap {
          for opname in sortedKeys(opdefs) {
            let op = opdefs[opname] ?? .null
            var points: [Json] = []
            if let pdefs = op.get("points").asList {
              for p in pdefs {
                var path = p.get("orig")
                if path.isNull {
                  path = p.get("path")
                }

                var params: [Json] = []
                if let parts = p.get("parts").asList {
                  for part in parts {
                    if let text = part.asStr, text.hasPrefix(":") {
                      params.append(.str(String(text.dropFirst())))
                    }
                  }
                }

                var point: [String: Json] = [
                  "method": .str(p.get("method").asStr ?? ""),
                  "path": .str(jsonText(path) ?? ""),
                  "params": .list(params),
                ]
                if p.has("select"), !p.get("select").isNull {
                  point["select"] = p.get("select")
                }
                points.append(.map(point))
              }
            }
            ops[opname] = .map(["points": .list(points)])
          }
        }

        entities[ename] = .map([
          "fields": .map(fields),
          "ops": .map(ops),
        ])
      }
    }

    var features: [Json] = []
    if let featdefs = config.get("feature").asMap {
      for fname in sortedKeys(featdefs) {
        let active = true == activeFeatures.get(fname).get("active").asBool
        features.append(.map([
          "name": .str(fname),
          "active": .bool(active),
        ]))
      }
    }

    let descriptor: Json = .map([
      "station": .num(1),
      "name": .str(name),
      "slug": .str(slug),
      "envtoken": .str(envToken(slug)),
      "version": .str(version),
      "target": .str(target),
      "base": .str(options.get("base").asStr ?? ""),
      "server": .list(server),
      "auth": auth,
      "entities": .map(entities),
      "features": .list(features),
    ])

    return (descriptor, warnings)
  }

  /// Canonical serialization (design 4): UTF-8, object keys sorted
  /// bytewise, no insignificant whitespace, minimal JSON escaping. The
  /// proxy dedupes registrations by a hash of this, so every language
  /// must produce identical bytes - the `canonical-serialize` corpus
  /// section carries the adversarial cases.
  public static func canonicalSerialize(_ value: Json) -> String {
    var out = ""
    serialize(value, &out)
    return out
  }

  private static func serialize(_ value: Json, _ out: inout String) {
    switch value {
    case .null:
      out += "null"
    case .bool(let flag):
      out += flag ? "true" : "false"
    case .num(let num):
      out += numStr(num)
    case .str(let text):
      quote(text, &out)
    case .list(let items):
      out += "["
      for (index, item) in items.enumerated() {
        if 0 < index {
          out += ","
        }
        serialize(item, &out)
      }
      out += "]"
    case .map(let entries):
      let keys = entries.keys.sorted(by: utf8Less)
      out += "{"
      var first = true
      for key in keys {
        if !first {
          out += ","
        }
        first = false
        quote(key, &out)
        out += ":"
        serialize(entries[key] ?? .null, &out)
      }
      out += "}"
    }
  }

  // Integral numbers print without a decimal point or exponent, matching
  // the canonical JSON.stringify behaviour (2^53-1 stays exact).
  static func numStr(_ num: Double) -> String {
    if num.isFinite, num == num.rounded(.down),
      num >= -9_223_372_036_854_775_808.0, num <= 9_223_372_036_854_775_807.0
    {
      return String(Int64(num))
    }
    return "\(num)"
  }

  // Minimal JSON escaping: quote, backslash, and control characters
  // only; everything else (non-ASCII included) passes through as UTF-8.
  static func quote(_ text: String, _ out: inout String) {
    out += "\""
    for ch in text.unicodeScalars {
      switch ch {
      case "\"":
        out += "\\\""
      case "\\":
        out += "\\\\"
      case "\u{8}":
        out += "\\b"
      case "\u{c}":
        out += "\\f"
      case "\n":
        out += "\\n"
      case "\r":
        out += "\\r"
      case "\t":
        out += "\\t"
      default:
        if ch.value < 0x20 {
          out += String(format: "\\u%04x", ch.value)
        } else {
          out.unicodeScalars.append(ch)
        }
      }
    }
    out += "\""
  }

  // Bytewise key order: compare UTF-8 byte sequences, not code points or
  // locale collation. (UTF-8 bytewise order equals code-point order, but
  // stating it as bytes is the corpus's contract.)
  static func utf8Less(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8)
    let bb = Array(b.utf8)
    let n = min(ab.count, bb.count)
    var index = 0
    while index < n {
      if ab[index] != bb[index] {
        return ab[index] < bb[index]
      }
      index += 1
    }
    return ab.count < bb.count
  }

  // A string form of a scalar (string or number), or nil - the config's
  // version may legally be a number in a hand-written config.
  static func jsonText(_ val: Json) -> String? {
    if let text = val.asStr {
      return text.isEmpty ? nil : text
    }
    if let num = val.asNum {
      return numStr(num)
    }
    return nil
  }

  static func sortedKeys(_ entries: [String: Json]) -> [String] {
    return entries.keys.sorted(by: utf8Less)
  }
}
