// station.json loading and profile resolution (station design 3.5): one
// total order, identical in every library, pinned by the `instance`
// corpus section. Design 3.3's merge is ONE FLAT LEFT-TO-RIGHT
// interleave over the api and sdk block levels, EXCEPT
// secrets.providers, which replaces wholesale - chain order decides
// which store wins, so a positional merge would be actively dangerous
// (design 5.2, 11).
//
// A port of typescript/src/profile.ts, which is canonical.

import Foundation

public enum Profile {

  /// station.json lookup: cwd upward to the repo root, then
  /// ~/.voxgig/station.json (design 3.5). A repo root is where .git
  /// lives; with no repo the walk stops at the filesystem root.
  public static func findConfigFile(_ from: String?) -> String? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: (from?.isEmpty ?? true)
      ? fm.currentDirectoryPath : from!).standardizedFileURL.path

    while true {
      let candidate = dir + "/station.json"
      if fm.fileExists(atPath: candidate) {
        return candidate
      }
      let atRepoRoot = fm.fileExists(atPath: dir + "/.git")
      let parent = (dir as NSString).deletingLastPathComponent
      if atRepoRoot || parent == dir || parent.isEmpty {
        break
      }
      dir = parent
    }

    let home = NSHomeDirectory() + "/.voxgig/station.json"
    return fm.fileExists(atPath: home) ? home : nil
  }

  /// The parsed station.json, or nil when none is found. A file that IS
  /// found and does not parse is a config error, not a raw JsonError
  /// escaping open(): the reader found station.json and could not use
  /// it, which is exactly what station_config_invalid exists to say.
  public static func loadConfig(_ from: String?) throws -> Json? {
    guard let file = findConfigFile(from) else {
      return nil
    }
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
      return nil
    }
    do {
      return try Json.parse(text)
    } catch {
      throw StationError(
        "station_config_invalid",
        "station.json at " + file + " is not valid JSON: "
          + ((error as? JsonError)?.message ?? "\(error)"))
    }
  }

  /// Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
  /// else 'default' (design 3.5 - open() opts win over env vars, which
  /// win over station.json).
  public static func selectProfile(_ optProfile: String?) -> String {
    if let opt = optProfile, !opt.isEmpty {
      return opt
    }
    if let env = SecretBroker.envValue("VOXGIG_STATION_PROFILE"), !env.isEmpty {
      return env
    }
    return "default"
  }

  /// The one block key carrying the timing rule: its default is applied
  /// AFTER the merge, never before (design 3.3, 4.2).
  public static let MERGE_SENSITIVE: [String] = ["active"]

  /// The block defaults, allocated FRESH per application so no two
  /// instances ever share one `feature` map. `active` is a real JSON
  /// boolean - the corpus compares the serialized value.
  static func blockDefaults() -> [String: Json] {
    return [
      "active": .bool(true),
      "feature": .map([:]),
    ]
  }

  /// The api half of a ref: the substring before the first `$`; an
  /// untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
  /// point: under the old free-form identity which api an instance used
  /// was itself a merged value, so a port that got the phasing wrong
  /// silently picked another api's defaults.
  public static func refapi(_ ref: String) -> String {
    if let at = ref.firstIndex(of: "$") {
      return String(ref[..<at])
    }
    return ref
  }

  /// Shallow merge, per key, left to right - each source over the one
  /// before it, non-maps skipped. ONE level only: an overlay's `policy`
  /// REPLACES the base's entirely rather than merging `hosts` into it -
  /// an allowlist that widens because two precedence levels merged is
  /// the failure this rule prevents.
  static func shallow(_ sources: Json...) -> [String: Json] {
    var out: [String: Json] = [:]
    for src in sources {
      guard let entries = src.asMap else { continue }
      for (key, entry) in entries {
        out[key] = entry
      }
    }
    return out
  }

  /// Sorted union of the keys of every map argument (non-maps skipped).
  /// Named apart from Descriptor.sortedKeys, the single-map sort.
  static func mergedKeys(_ maps: Json...) -> [String] {
    var keys = Set<String>()
    for m in maps {
      if let entries = m.asMap {
        keys.formUnion(entries.keys)
      }
    }
    return keys.sorted(by: Descriptor.utf8Less)
  }

  /// Merge the base profile ('default') with the selected overlay.
  ///
  /// Design 3.3's total order for the two block levels, lowest
  /// precedence first:
  ///
  ///   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
  ///
  /// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE
  /// FLAT LEFT-TO-RIGHT MERGE. It must not be reorganized into
  /// "collapse each namespace, then put instance over api" - that lets
  /// every instance value beat every api value, so a production
  /// `api.stripe.policy` would fail to override a default profile's
  /// `sdk.stripe$test.policy`, silently keeping the wider allowlist in
  /// production.
  ///
  /// `secrets.providers` replaces wholesale, never merges (design 3.5,
  /// 5.2). Returns {name, providers, api, sdk}; a configured secret
  /// name sekreto rejects, or a derived-name collision, fails here at
  /// profile load rather than first request (design 14).
  public static func resolveProfile(_ config: Json, _ profileName: String) throws -> Json {
    let profiles = config.get("profiles")
    let base = profiles.get("default")
    let overlay: Json = "default" == profileName ? .map([:]) : profiles.get(profileName)

    var providers = overlay.get("secrets").get("providers")
    if nil == providers.asList {
      providers = base.get("secrets").get("providers")
    }
    if nil == providers.asList {
      providers = .list([.map(["kind": .str("env")])])
    }

    let baseApi = base.get("api")
    let overApi = overlay.get("api")
    let baseSdk = base.get("sdk")
    let overSdk = overlay.get("sdk")

    // The api-level defaults in effect for this profile, keyed by api
    // slug. A REPORT, not an input to the instance merge below -
    // collapsing each namespace first and composing at the end is the
    // exact algorithm design 3.3 forbids - and it takes NO block
    // defaults.
    var api: [String: Json] = [:]
    for slug in mergedKeys(baseApi, overApi) {
      api[slug] = .map(shallow(baseApi.get(slug), overApi.get(slug)))
    }

    // Instances, keyed by REF. An api block declares no instance of its
    // own (design 3.1), so the ref set comes from the two sdk maps
    // alone.
    var sdk: [String: Json] = [:]
    for ref in mergedKeys(baseSdk, overSdk) {
      let a = refapi(ref)
      var merged = shallow(
        baseApi.get(a), baseSdk.get(ref), overApi.get(a), overSdk.get(ref))

      // Defaults are applied ONCE, to the fully merged instance. Had
      // the overlay block carried a synthesized `active` into the
      // merge, a one-key environment override would silently re-enable
      // an integration the base declared inactive. Key MEMBERSHIP, not
      // isNull on a get: an explicit false, {} - or JSON null - must
      // survive the merge untouched.
      for (key, entry) in blockDefaults() where nil == merged[key] {
        merged[key] = entry
      }

      sdk[ref] = .map(merged)
    }

    try checksecrets(sdk, profileName)

    return .map([
      "name": .str(profileName),
      "providers": providers,
      "api": .map(api),
      "sdk": .map(sdk),
    ])
  }

  /// A configured secret name sekreto would reject is caught at profile
  /// load, not first request (design 14 station_secret_name) - and then
  /// the DERIVED names are checked for uniqueness, because envToken is
  /// LOSSY: it collapses any run of non-alphanumerics to `_`, so
  /// `stripe$test` and an untagged instance of a `stripe-test` api both
  /// derive `stripe_test.apikey` and would silently share one
  /// credential.
  ///
  /// Two instances that EXPLICITLY name one secret are not a collision -
  /// that is the shared-key case the api-level `secret` exists for.
  private static func checksecrets(_ sdk: [String: Json], _ profileName: String) throws {
    let refs = sdk.keys.sorted(by: Descriptor.utf8Less)

    for ref in refs {
      let name = sdk[ref]?.get("secret") ?? .null
      if !name.isNull, !SecretBroker.validname(name.asStr) {
        throw StationError(
          "station_secret_name",
          "profile \"" + profileName + "\" sdk \"" + ref
            + "\": secret name rejected by sekreto: "
            + Descriptor.canonicalSerialize(name))
      }
    }

    var seen: [String: (ref: String, derived: Bool)] = [:]
    for ref in refs {
      let written = (sdk[ref]?.get("secret") ?? .null).asStr ?? ""
      let derived = written.isEmpty
      let name = derived ? Descriptor.secretnameDefault(ref) : written

      if let prior = seen[name] {
        if derived || prior.derived {
          throw StationError(
            "station_secret_collision",
            "profile \"" + profileName + "\": instances \"" + prior.ref
              + "\" and \"" + ref + "\" both resolve to secret name \""
              + name + "\", so they would share one credential; name it "
              + "explicitly on each, or at the api level to share it "
              + "deliberately (5.1)")
        }
      } else {
        seen[name] = (ref: ref, derived: derived)
      }
    }
  }
}
