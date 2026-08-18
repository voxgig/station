// station.json loading and profile resolution (station design 3.5): one
// total order, identical in every library, pinned by the `profile` corpus
// section. The overlay deep-merges per plugin, EXCEPT secrets.providers,
// which replaces wholesale - chain order decides which store wins, so a
// positional merge would be actively dangerous (design 5.2, 11).
//
// A port of typescript/src/profile.ts, which is canonical.

package com.voxgig.station;

import com.voxgig.sekreto.Json;
import com.voxgig.sekreto.Sekreto;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@SuppressWarnings({"unchecked"})
public final class Profile {

  private Profile() {}

  /**
   * station.json lookup: cwd upward to the repo root, then
   * ~/.voxgig/station.json (design 3.5). A repo root is where .git lives;
   * with no repo the walk stops at the filesystem root.
   */
  public static String findConfigFile(String from) {
    Path dir = Paths.get(null == from || from.isEmpty()
        ? System.getProperty("user.dir") : from).toAbsolutePath().normalize();

    while (true) {
      Path candidate = dir.resolve("station.json");
      if (Files.exists(candidate)) {
        return candidate.toString();
      }
      boolean atRepoRoot = Files.exists(dir.resolve(".git"));
      Path parent = dir.getParent();
      if (atRepoRoot || null == parent || parent.equals(dir)) {
        break;
      }
      dir = parent;
    }

    Path home = Paths.get(System.getProperty("user.home"), ".voxgig", "station.json");
    return Files.exists(home) ? home.toString() : null;
  }

  /** The parsed station.json, or null when none is found. */
  public static Map<String, Object> loadConfig(String from) {
    String file = findConfigFile(from);
    if (null == file) {
      return null;
    }
    try {
      String text = new String(
          Files.readAllBytes(Paths.get(file)), StandardCharsets.UTF_8);
      Object parsed = Json.parse(text);
      return Descriptor.asmap(parsed);
    } catch (IOException err) {
      throw new RuntimeException("station: cannot read " + file + ": " + err.getMessage(), err);
    }
  }

  /**
   * Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
   * else 'default' (design 3.5 - open() opts win over env vars, which win
   * over station.json).
   */
  public static String selectProfile(String optProfile) {
    if (null != optProfile && !optProfile.isEmpty()) {
      return optProfile;
    }
    String env = System.getenv("VOXGIG_STATION_PROFILE");
    if (null != env && !env.isEmpty()) {
      return env;
    }
    return "default";
  }

  /**
   * Merge the base profile ('default') with the selected overlay:
   * deep-merge per plugin, EXCEPT secrets.providers which replaces
   * wholesale. Returns { name, providers, plugin }; a configured secret
   * name sekreto would reject fails here (station_secret_name), at
   * profile load rather than first request (design 14).
   */
  public static Map<String, Object> resolveProfile(Object config, String profileName) {
    Map<String, Object> profiles = Descriptor.asmap(Descriptor.getprop(config, "profiles"));
    Map<String, Object> base = Descriptor.asmap(profiles.get("default"));
    Map<String, Object> overlay = "default".equals(profileName)
        ? new LinkedHashMap<>() : Descriptor.asmap(profiles.get(profileName));

    Object providers = Descriptor.getprop(overlay.get("secrets"), "providers");
    if (null == providers) {
      providers = Descriptor.getprop(base.get("secrets"), "providers");
    }
    if (null == providers) {
      Map<String, Object> env = new LinkedHashMap<>();
      env.put("kind", "env");
      providers = List.of(env);
    }

    Map<String, Object> plugin = new LinkedHashMap<>();
    for (Map<String, Object> src : List.of(
        Descriptor.asmap(base.get("plugin")),
        Descriptor.asmap(overlay.get("plugin")))) {
      for (Map.Entry<String, Object> entry : src.entrySet()) {
        Map<String, Object> merged = new LinkedHashMap<>(
            Descriptor.asmap(plugin.get(entry.getKey())));
        merged.putAll(Descriptor.asmap(entry.getValue()));
        plugin.put(entry.getKey(), merged);
      }
    }

    for (Map.Entry<String, Object> entry : plugin.entrySet()) {
      Object name = Descriptor.getprop(entry.getValue(), "secret");
      if (null != name && !Sekreto.validname(name)) {
        throw new StationError("station_secret_name",
            "profile \"" + profileName + "\" plugin \"" + entry.getKey()
                + "\": secret name rejected by sekreto: \"" + name + "\"");
      }
    }

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("name", profileName);
    out.put("providers", providers);
    out.put("plugin", plugin);
    return out;
  }
}
