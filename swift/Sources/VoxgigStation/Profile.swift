// station.json loading and profile resolution (station design 3.5): one
// total order, identical in every library, pinned by the `profile` corpus
// section. The overlay deep-merges per plugin, EXCEPT secrets.providers,
// which replaces wholesale - chain order decides which store wins, so a
// positional merge would be actively dangerous (design 5.2, 11).
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

  /// The parsed station.json, or nil when none is found.
  public static func loadConfig(_ from: String?) throws -> Json? {
    guard let file = findConfigFile(from) else {
      return nil
    }
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
      return nil
    }
    return try Json.parse(text)
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

  /// Merge the base profile ('default') with the selected overlay:
  /// deep-merge per plugin, EXCEPT secrets.providers which replaces
  /// wholesale. Returns {name, providers, plugin}; a configured secret
  /// name sekreto's name rules reject fails here (station_secret_name),
  /// at profile load rather than first request (design 14).
  public static func resolveProfile(_ config: Json, _ profileName: String) throws -> Json {
    let profiles = config.get("profiles")
    let baseProfile = profiles.get("default")
    let overlay: Json = "default" == profileName ? .map([:]) : profiles.get(profileName)

    var providers = overlay.get("secrets").get("providers")
    if providers.isNull {
      providers = baseProfile.get("secrets").get("providers")
    }
    if providers.isNull {
      providers = .list([.map(["kind": .str("env")])])
    }

    var plugin: [String: Json] = [:]
    for src in [baseProfile.get("plugin"), overlay.get("plugin")] {
      guard let entries = src.asMap else { continue }
      for key in Descriptor.sortedKeys(entries) {
        var merged = plugin[key]?.asMap ?? [:]
        if let add = entries[key]?.asMap {
          for (k, v) in add {
            merged[k] = v
          }
        }
        plugin[key] = .map(merged)
      }
    }

    for slug in Descriptor.sortedKeys(plugin) {
      let name = plugin[slug]?.asMap?["secret"]
      if let name = name, !name.isNull, !SecretBroker.validname(name.asStr) {
        throw StationError(
          "station_secret_name",
          "profile \"" + profileName + "\" plugin \"" + slug
            + "\": secret name rejected by sekreto's name rules: "
            + Descriptor.canonicalSerialize(name))
      }
    }

    return .map([
      "name": .str(profileName),
      "providers": providers,
      "plugin": .map(plugin),
    ])
  }
}
