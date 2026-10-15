// The secret broker (station design 5): a resolver names a secret,
// station places the value where the application cannot reach it. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical - with the one
// honest divergence the tier table (station design 2.2) requires: **no
// Swift sekreto port exists, so this library is env-only for secrets and
// says so.** It reads the process environment directly under the envtoken
// name - the one provider that needs no library - and refuses, rather
// than pretends, when a chain names any other store:
//
//   - an `env` provider that does not hold the name is a MISS and the
//     chain carries on (station_secret_no_value when every store missed);
//   - any non-env provider kind is a store this port CANNOT ANSWER from,
//     which per station design 5.2 is an error (station_secret_error),
//     never a fall-through - skipping it would quietly reach for a
//     weaker store.
//
// The permanent fix is a sekreto Swift port, contributed to sekreto
// (station design 18); until then, attached-mode proxy-side resolution is
// the path to vaults for Swift apps, and this broker covers exactly solo.
//
// The two sekreto name rules this port needs are restated here EXACTLY
// once (sekreto typescript/src/Sekreto.ts validname/envkey - the corpus
// `secretname` section pins the round-trip): a name is dot-separated
// segments of [a-z0-9_]+, and its env key joins the segments with '_' and
// upper-cases.

import Foundation

#if canImport(Glibc)
  import Glibc
#endif

public final class SecretBroker {

  public static func placeholderFor(_ slug: String) -> String {
    return "[station:" + slug + "]"
  }

  private static let hexDigits: [Character] = Array("0123456789ABCDEF")

  /// Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
  public static func encodeQueryValue(_ value: String) -> String {
    var out = ""
    for byte in value.utf8 {
      if isUnreserved(byte) {
        out.append(Character(Unicode.Scalar(byte)))
      } else {
        out.append("%")
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
      }
    }
    return out
  }

  /// The placeholder becomes the value in header values and in the URL
  /// query, where an SDK percent-encodes it (any hex case) and the value is
  /// encoded in turn. The path and fragment are never touched; the headers
  /// are a copy.
  public static func substitute(
    _ url: String, _ headers: [String: String]?, _ placeholder: String, _ value: String
  ) -> (url: String, headers: [String: String]) {
    var out = headers ?? [:]
    if placeholder.isEmpty {
      return (url: url, headers: out)
    }
    for (name, text) in out where text.contains(placeholder) {
      out[name] = text.replacingOccurrences(of: placeholder, with: value)
    }

    let bytes = Array(url.utf8)
    let hash = bytes.firstIndex(of: 0x23)
    guard let q = bytes.firstIndex(of: 0x3F), hash.map({ q < $0 }) ?? true else {
      return (url: url, headers: out)
    }
    let end = hash ?? bytes.count
    let find = Array(placeholder.utf8)
    let encoded = Array(encodeQueryValue(value).utf8)
    var sent = Array(bytes[...q])
    var i = q + 1
    while i < end {
      if let n = matchAt(bytes, i, end, find) {
        sent += encoded
        i += n
      } else {
        sent.append(bytes[i])
        i += 1
      }
    }
    sent += bytes[end...]
    return (url: String(decoding: sent, as: UTF8.self), headers: out)
  }

  // The placeholder's length at `at`, each of its bytes literal or as %XX
  // in either hex case; nil when it is not there.
  private static func matchAt(
    _ bytes: [UInt8], _ at: Int, _ end: Int, _ find: [UInt8]
  ) -> Int? {
    var i = at
    for ch in find {
      if i < end && bytes[i] == ch {
        i += 1
        continue
      }
      if i + 3 <= end && 0x25 == bytes[i],
        let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]),
        hi * 16 + lo == ch
      {
        i += 3
        continue
      }
      return nil
    }
    return i - at
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: return byte - 0x30
    case 0x41...0x46: return byte - 0x37
    case 0x61...0x66: return byte - 0x57
    default: return nil
    }
  }

  private static func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: return true
    default: return false
    }
  }

  /// sekreto's validname: dot-separated lowercase segments of [a-z0-9_]+.
  public static func validname(_ name: String?) -> Bool {
    guard let name = name, !name.isEmpty else { return false }
    for segment in name.split(separator: ".", omittingEmptySubsequences: false) {
      if segment.isEmpty {
        return false
      }
      for scalar in segment.unicodeScalars {
        let ok = ("a" <= scalar && scalar <= "z") || ("0" <= scalar && scalar <= "9")
          || "_" == scalar
        if !ok {
          return false
        }
      }
    }
    return true
  }

  /// sekreto's envkey: 'voxgig_solardemo.apikey' -> 'VOXGIG_SOLARDEMO_APIKEY'.
  public static func envkey(_ name: String, _ prefix: String = "") -> String {
    return prefix + name.split(separator: ".", omittingEmptySubsequences: false)
      .joined(separator: "_").uppercased()
  }

  // The provider chain, in sekreto's own declarative ProviderSpec form,
  // passed through untouched (design 5.2). An empty or absent chain is
  // the default [{kind: 'env'}] - today's behaviour.
  private let providers: [Json]

  // Values hoisted by adopt-style binding from a resident options apikey
  // (design 3.1).
  private var overrides: [String: String] = [:]
  private var cache: [String: String] = [:]

  // Every value this broker ever held, for the exact-value scrub.
  private var held: [String] = []

  private let gate = NSLock()

  public init(_ providerSpecs: Json) {
    if let list = providerSpecs.asList, !list.isEmpty {
      providers = list
    } else {
      providers = [.map(["kind": .str("env")])]
    }
  }

  public func hoist(_ slug: String, _ value: String) {
    gate.lock()
    defer { gate.unlock() }
    overrides[slug] = value
    held.append(value)
  }

  /// Resolve the value for a plugin's secret name. Misses and store
  /// errors keep sekreto's distinction (design 5.2): a miss is
  /// station_secret_no_value, a store that could not answer is
  /// station_secret_error - and never a retry against a weaker store.
  public func value(_ slug: String, _ name: String) throws -> String {
    gate.lock()
    defer { gate.unlock() }

    if let over = overrides[slug] {
      return over
    }
    if let cached = cache[slug] {
      return cached
    }

    guard SecretBroker.validname(name) else {
      throw StationError(
        "station_secret_error",
        "invalid secret name (sekreto name rules): \"" + name + "\"")
    }

    for provider in providers {
      let kind = provider.get("kind").asStr
      guard "env" == kind else {
        throw StationError(
          "station_secret_error",
          "provider kind \"" + (kind ?? "") + "\" is unavailable: no swift sekreto "
            + "port exists, so solo mode is env-only (station design 2.2); the "
            + "chain stops here rather than falling through to a weaker store "
            + "(station design 5.2)")
      }
      let prefix = provider.get("prefix").asStr ?? ""
      if let found = SecretBroker.envValue(SecretBroker.envkey(name, prefix)) {
        cache[slug] = found
        held.append(found)
        return found
      }
    }

    throw StationError(
      "station_secret_no_value",
      "no store had \"" + name + "\" for plugin \"" + slug + "\"")
  }

  /// The provider kinds this env-only port cannot serve, for the says-so
  /// warning at construction (design 2.2).
  public func unsupportedKinds() -> [String] {
    var out: [String] = []
    for provider in providers {
      let kind = provider.get("kind").asStr ?? ""
      if "env" != kind && !out.contains(kind) {
        out.append(kind)
      }
    }
    return out
  }

  /// Exact-value scrub, deliberately WITHOUT sekreto's four-character
  /// readability floor (design 7 as revised): on boundaries where the
  /// promise is absolute, every held value is scrubbed whatever its
  /// length. There is no sekreto instance underneath this env-only
  /// broker, so the held list is the complete set of values ever
  /// resolved or hoisted - nothing more to delegate to. Every form is
  /// matched against the original text and the union of the matches
  /// redacted, so no replacement can hide another form.
  public func scrub(_ text: String) -> String {
    gate.lock()
    defer { gate.unlock() }
    let forms: [[UInt8]] = held.filter { !$0.isEmpty }.flatMap {
      [Array($0.utf8), Array(SecretBroker.encodeQueryValue($0).utf8)]
    }
    let bytes = Array(text.utf8)
    func reach(_ at: Int) -> Int {
      var end = at
      for form in forms where at + form.count > end && at + form.count <= bytes.count {
        if bytes[at..<(at + form.count)].elementsEqual(form) {
          end = at + form.count
        }
      }
      return end
    }

    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
      var stop = reach(i)
      if stop == i {
        out.append(bytes[i])
        i += 1
        continue
      }
      var j = i + 1
      while j < stop {
        stop = max(stop, reach(j))
        j += 1
      }
      out += Array("[redacted]".utf8)
      i = stop
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Drop the cache so the next resolve asks the stores again (rotation
  /// support, design 5.3). Hoisted overrides survive, as in the
  /// canonical broker.
  public func refresh() {
    gate.lock()
    defer { gate.unlock() }
    cache.removeAll()
  }

  // getenv, not ProcessInfo.environment: the C accessor always reads the
  // CURRENT environ, where Foundation may snapshot - and the test seam
  // (setenv between cases) depends on reads being current.
  static func envValue(_ key: String) -> String? {
    guard let raw = getenv(key) else { return nil }
    return String(cString: raw)
  }
}
