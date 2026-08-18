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
  /// resolved or hoisted - nothing more to delegate to.
  public func scrub(_ text: String) -> String {
    gate.lock()
    defer { gate.unlock() }
    var out = text
    for value in held where !value.isEmpty {
      out = out.replacingOccurrences(of: value, with: "[redacted]")
    }
    return out
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
