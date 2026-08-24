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
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.function.Supplier;

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
    String text;
    try {
      text = new String(
          Files.readAllBytes(Paths.get(file)), StandardCharsets.UTF_8);
    } catch (IOException err) {
      throw new RuntimeException("station: cannot read " + file + ": " + err.getMessage(), err);
    }
    // A file that is not JSON is a CONFIG ERROR, not a raw parse error
    // escaping open(): the reader found station.json and could not use it,
    // which is exactly what station_config_invalid exists to say.
    try {
      return Descriptor.asmap(Json.parse(text));
    } catch (RuntimeException err) {
      throw new StationError("station_config_invalid",
          "station.json at " + file + " is not valid JSON: " + err.getMessage());
    }
  }

  /**
   * Which side of the repo review boundary the discovered station.json came
   * from (design 6.3): 'none' when no file was found, 'user' when the file
   * found is ~/.voxgig/station.json, else 'repo'.
   *
   * <p>`package` and `export` are honoured only from REPO-SCOPED config,
   * because a user-level file is outside the repo's review boundary and a
   * `package` key arriving from it names code to import. Everything else in
   * a user-level config still applies - this narrows one key rather than
   * distrusting the file.
   */
  public static String configScope(String from) {
    String file = findConfigFile(from);
    if (null == file) {
      return "none";
    }
    Path home = Paths.get(System.getProperty("user.home"), ".voxgig", "station.json");
    return home.toString().equals(file) ? "user" : "repo";
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
  /** The api half of a ref is the substring before the first `$`, and an
   * untagged ref IS an api slug (design 3.4).
   *
   * LEXICAL, and that is the point: under the old free-form identity
   * which api an instance used was itself a merged value, so a port that
   * got the phasing wrong silently picked another api's defaults. */
  public static String refapi(String ref) {
    int at = ref.indexOf('$');
    return -1 == at ? ref : ref.substring(0, at);
  }

  /** Shallow merge, per key, left to right - each source over the one
   * before it. An overlay's `policy` REPLACES the base's entirely rather
   * than merging `hosts` into it; an allowlist that widens because two
   * precedence levels merged is the failure this rule prevents. */
  @SafeVarargs
  private static Map<String, Object> shallow(Map<String, Object>... sources) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map<String, Object> src : sources) {
      if (null != src) {
        out.putAll(src);
      }
    }
    return out;
  }

  @SafeVarargs
  private static List<String> mergedKeys(Map<String, Object>... maps) {
    TreeSet<String> keys = new TreeSet<>();
    for (Map<String, Object> m : maps) {
      if (null != m) {
        keys.addAll(m.keySet());
      }
    }
    return new ArrayList<>(keys);
  }

  /** Merge the base profile ('default') with the selected overlay.
   *
   * Design 3.3's total order for the two block levels, lowest first:
   *
   *   base.api[api] + base.sdk[ref] + overlay.api[api] + overlay.sdk[ref]
   *
   * PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
   * LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
   * namespace, then put instance over api" - that lets every instance
   * value beat every api value, so a production `api.stripe.policy` would
   * fail to override a default profile's `sdk.stripe$test.policy`,
   * silently keeping the wider allowlist in production.
   *
   * `secrets.providers` replaces wholesale, never merges (3.5, 5.2). */
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

    Map<String, Object> baseApi = Descriptor.asmap(base.get("api"));
    Map<String, Object> overApi = Descriptor.asmap(overlay.get("api"));
    Map<String, Object> baseSdk = Descriptor.asmap(base.get("sdk"));
    Map<String, Object> overSdk = Descriptor.asmap(overlay.get("sdk"));

    // The api-level defaults in effect for this profile. A REPORT, not
    // an input to the instance merge below.
    Map<String, Object> api = new LinkedHashMap<>();
    for (String slug : mergedKeys(baseApi, overApi)) {
      api.put(slug, shallow(
          Descriptor.asmap(baseApi.get(slug)), Descriptor.asmap(overApi.get(slug))));
    }

    // An api block declares no instance of its own (3.1), so the ref set
    // comes from the two `sdk` maps alone.
    Map<String, Object> sdk = new LinkedHashMap<>();
    for (String ref : mergedKeys(baseSdk, overSdk)) {
      String a = refapi(ref);
      Map<String, Object> merged = shallow(
          Descriptor.asmap(baseApi.get(a)), Descriptor.asmap(baseSdk.get(ref)),
          Descriptor.asmap(overApi.get(a)), Descriptor.asmap(overSdk.get(ref)));

      // Defaults are applied ONCE, to the fully merged instance. Had the
      // overlay block carried a synthesized `active` into the merge, a
      // one-key environment override would silently re-enable an
      // integration the base declared inactive.
      // Shape.blockDefaults() is ONE TABLE WITH TWO CALLERS AT DIFFERENT
      // MOMENTS: validateConfig applies it BEFORE the merge, to every
      // block, because a block with no present keys is an open map; this
      // applies it AFTER, to the merged instance, because an absent key
      // must stay absent through the merge. Shape.MERGE_SENSITIVE names
      // `active` explicitly so this can be asserted rather than inferred.
      for (Map.Entry<String, Supplier<Object>> d
          : Shape.blockDefaults().entrySet()) {
        if (!merged.containsKey(d.getKey())) {
          merged.put(d.getKey(), d.getValue().get());
        }
      }

      sdk.put(ref, merged);
    }

    checksecrets(sdk, profileName);

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("name", profileName);
    out.put("providers", providers);
    out.put("api", api);
    out.put("sdk", sdk);
    return out;
  }

  /** A configured secret name sekreto would reject is caught at profile
   * load, not first request (14 station_secret_name) - and then the
   * DERIVED names are checked for uniqueness, because envtoken is lossy:
   * it collapses any run of non-alphanumerics to `_`, so `stripe$test`
   * and an untagged instance of a `stripe-test` api both derive
   * `stripe_test.apikey` and would silently share one credential.
   *
   * Two instances that EXPLICITLY name one secret are not a collision -
   * that is the shared-key case the api-level `secret` exists for. */
  private static void checksecrets(Map<String, Object> sdk, String profileName) {
    List<String> refs = new ArrayList<>(new TreeSet<>(sdk.keySet()));

    for (String ref : refs) {
      Object name = Descriptor.getprop(sdk.get(ref), "secret");
      if (null != name && !Sekreto.validname(name)) {
        throw new StationError("station_secret_name",
            "profile \"" + profileName + "\" sdk \"" + ref
                + "\": secret name rejected by sekreto: \"" + name + "\"");
      }
    }

    Map<String, String[]> seen = new LinkedHashMap<>();
    for (String ref : refs) {
      Object written = Descriptor.getprop(sdk.get(ref), "secret");
      boolean derived = null == written || "".equals(written);
      String name = derived
          ? Descriptor.secretnameDefault(ref) : String.valueOf(written);

      String[] prior = seen.get(name);
      if (null != prior && (derived || "1".equals(prior[1]))) {
        throw new StationError("station_secret_collision",
            "profile \"" + profileName + "\": instances \"" + prior[0]
                + "\" and \"" + ref + "\" both resolve to secret name \"" + name
                + "\", so they would share one credential; name it explicitly "
                + "on each, or at the api level to share it deliberately (5.1)");
      }
      if (null == prior) {
        seen.put(name, new String[] { ref, derived ? "1" : "0" });
      }
    }
  }
}
