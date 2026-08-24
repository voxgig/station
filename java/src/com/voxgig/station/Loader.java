// design 6.3's loader - and why this port does not have one.
//
// THE LOADER DOES NOT PORT EVERYWHERE. It closes the loop for a language
// that can import a module BY NAME at run time: station imports
// `api.<slug>.package`, the import self-registers, and the factory is
// there. Java cannot do that. An `import` is a compile-time name alias
// that loads nothing; a `package` value in station.json is a MODULE NAME
// in some other language's registry, not a Java class name, and guessing a
// class from it would be a road with no end.
//
// So this port implements design 5.4's mandatory divergence instead:
//
//  1. `package` and `export` stay IN THE GRAMMAR - they are shape keys, the
//     corpus validates configs carrying them, and one station.json serves a
//     polyglot fleet.
//  2. They are IGNORED at run time, with one WARNING EVENT per api at
//     open(), never an error.
//  3. Station.resolveFactory has TWO paths, and station_no_factory names
//     only the remedies this port actually offers.
//  4. Station.load() is present and inert.
//  5. station_sdk_load stays in the design 14 catalog - it is repo-wide -
//     and nothing this port runs raises it.
//
// What survives is checkPackage, which is PURE and cheap: the rule for
// what may appear in that key at all. It is exported so a Java-side tool
// can hold a shared station.json to the same rule the loading ports apply,
// and it is called from nowhere in this port.
//
// A port of typescript/src/loader.ts, which is canonical - of the one
// piece of it that is language-independent.

package com.voxgig.station;

import java.util.ArrayList;
import java.util.List;

public final class Loader {

  private Loader() {}

  /**
   * The fixed alias every generated package exports. `export` defaults to
   * it rather than to a derived class name because it is the same
   * identifier in every generated package, where camelify(slug) + "SDK" is
   * a rule that has to be recomputed and can be wrong.
   */
  public static final String DEFAULT_EXPORT = "SDK";

  /**
   * Only MODULE NAMES, resolved by the host language's ordinary resolution
   * from the application root. Never a filesystem path, never a URL, never
   * anything relative.
   *
   * <p>THE SEGMENT CHECK IS NOT OPTIONAL AND IS NOT IMPLIED BY THE PREFIX
   * CHECKS. `pkg/../../escape` starts with neither `.` nor `/`, so a
   * first-character check passes it, and the host resolves it through
   * `node_modules/pkg/../../escape`, importing application-local code from
   * OUTSIDE the named dependency. The whole point of this function is that
   * a configured package stays inside the dependency graph a reviewer can
   * see.
   */
  public static String checkPackage(String api, Object pkg) {
    if (!(pkg instanceof String) || bad((String) pkg)) {
      throw new StationError("station_sdk_load",
          "api \"" + api + "\": `package` must be a module name resolved from "
              + "the application root, not a path or URL: "
              + Descriptor.canonicalSerialize(pkg));
    }
    return (String) pkg;
  }

  private static boolean bad(String pkg) {
    if (pkg.isEmpty()) {
      return true;
    }
    if (pkg.startsWith(".") || pkg.startsWith("/") || pkg.startsWith("~")) {
      return true;
    }
    if (pkg.contains("://") || pkg.contains("\\")) {
      return true;
    }
    for (String segment : pkg.split("/", -1)) {
      if (".".equals(segment) || "..".equals(segment)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Split on runs of non-alphanumerics, drop empties, upper-case each first
   * character, join: `stripe-eu` -> `StripeEu`. The SECOND attempt at a
   * constructor name in the loading ports; here it is the same rule, kept
   * so a Java-side tool reporting on a shared station.json spells the
   * derived name the way the loading ports do.
   */
  public static String camelify(String slug) {
    List<String> parts = new ArrayList<>();
    for (String part : (null == slug ? "" : slug).split("[^A-Za-z0-9]+")) {
      if (!part.isEmpty()) {
        parts.add(Character.toUpperCase(part.charAt(0)) + part.substring(1));
      }
    }
    return String.join("", parts);
  }
}
