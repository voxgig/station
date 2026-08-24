// The descriptor normalizer and canonical serializer (station design 4):
// a generated SDK's embedded config, normalized into descriptor v1 - a
// VIEW over the config, never a second model - plus the one canonical
// byte serialization every port must agree on.
//
// A port of typescript/src/descriptor.ts, which is canonical.

package com.voxgig.station;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

@SuppressWarnings({"unchecked"})
public final class Descriptor {

  private Descriptor() {}

  /** A normalized descriptor plus any legacy warnings. */
  public static final class Normalized {
    public final Map<String, Object> descriptor;
    public final List<String> warnings;

    Normalized(Map<String, Object> descriptor, List<String> warnings) {
      this.descriptor = descriptor;
      this.warnings = warnings;
    }
  }

  /**
   * The ONLY way to build an env-var token in station, mirroring sdkgen's
   * packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
   * `secretname` corpus section pins the round-trip against sekreto's
   * envkey() and sdkgen's envName() - the one place three grammars meet.
   */
  public static String envtoken(Object name) {
    return (null == name ? "" : String.valueOf(name))
        .toUpperCase()
        .replaceAll("[^A-Z0-9]+", "_")
        .replaceAll("^_+|_+$", "");
  }

  /**
   * The default sekreto name for a plugin (design 5.1): envtoken(slug)
   * lowercased, plus '.apikey'. sekreto's envkey() then yields exactly the
   * env var the SDK's README documents: gnarly_pets.apikey ->
   * GNARLY_PETS_APIKEY.
   */
  public static String secretnameDefault(String slug) {
    return envtoken(slug).toLowerCase() + ".apikey";
  }

  // Best-effort slug from a camel name, for SDKs whose embedded config
  // predates main.slug (design 4 legacy sentinels). The hyphen caveat is
  // real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT 'voxgig-solardemo' -
  // callers surface a warning event when this path is taken.
  static String legacySlug(String name) {
    return (null == name ? "" : name).toLowerCase();
  }

  /**
   * Normalize a generated SDK's embedded config into descriptor v1
   * (design 4). The config is the one every SDK carries (Config.main /
   * .feature / .options / .entity); the descriptor is a VIEW over it.
   * Returns the descriptor plus any legacy warnings.
   */
  public static Normalized normalizeDescriptor(Object config, Object activeFeatures) {
    List<String> warnings = new ArrayList<>();
    Map<String, Object> main = asmap(getprop(config, "main"));
    Map<String, Object> options = asmap(getprop(config, "options"));

    String name = textor(main.get("name"), "");
    String slug = textor(main.get("slug"), "");
    if (slug.isEmpty()) {
      slug = legacySlug(name);
      warnings.add("descriptor: legacy config has no main.slug; derived \"" + slug
          + "\" from the camel name - hyphens in the original name are lost");
    }

    String version = null == main.get("version") ? "0.0.0" : String.valueOf(main.get("version"));
    String target = null == main.get("target") ? "unknown" : String.valueOf(main.get("target"));

    List<Object> server = new ArrayList<>();
    Map<String, Object> svr = asmap(options.get("server"));
    for (String key : new TreeMap<>(svr).keySet()) {
      Map<String, Object> entry = new LinkedHashMap<>();
      entry.put("name", key);
      entry.put("value", String.valueOf(svr.get(key)));
      server.add(entry);
    }

    boolean authActive = null != options.get("auth");
    Map<String, Object> auth = new LinkedHashMap<>();
    auth.put("active", authActive);
    auth.put("prefix", authActive ? textor(getprop(options.get("auth"), "prefix"), "") : "");
    auth.put("secretname", secretnameDefault(slug));

    Map<String, Object> entities = new LinkedHashMap<>();
    Map<String, Object> entdefs = asmap(getprop(config, "entity"));
    for (String ename : new TreeMap<>(entdefs).keySet()) {
      Map<String, Object> e = asmap(entdefs.get(ename));

      Map<String, Object> fields = new LinkedHashMap<>();
      Object fdefs = e.get("fields");
      if (fdefs instanceof List) {
        for (Object f : (List<Object>) fdefs) {
          Object fname = getprop(f, "name");
          if (null != f && null != fname) {
            Object kind = getprop(f, "kind");
            if (null == kind) {
              kind = getprop(f, "type");
            }
            Map<String, Object> field = new LinkedHashMap<>();
            field.put("kind", null == kind ? "" : String.valueOf(kind));
            fields.put(String.valueOf(fname), field);
          }
        }
      }

      Map<String, Object> ops = new LinkedHashMap<>();
      Map<String, Object> opdefs = asmap(e.get("op"));
      for (String opname : new TreeMap<>(opdefs).keySet()) {
        Map<String, Object> op = asmap(opdefs.get(opname));
        List<Object> points = new ArrayList<>();
        Object pdefs = op.get("points");
        if (pdefs instanceof List) {
          for (Object p : (List<Object>) pdefs) {
            if (null == p) {
              continue;
            }
            Map<String, Object> point = new LinkedHashMap<>();
            point.put("method", textor(getprop(p, "method"), ""));
            Object path = getprop(p, "orig");
            if (null == path) {
              path = getprop(p, "path");
            }
            point.put("path", null == path ? "" : String.valueOf(path));

            List<Object> params = new ArrayList<>();
            Object parts = getprop(p, "parts");
            if (parts instanceof List) {
              for (Object part : (List<Object>) parts) {
                if (part instanceof String && ((String) part).startsWith(":")) {
                  params.add(((String) part).substring(1));
                }
              }
            }
            point.put("params", params);

            Object select = getprop(p, "select");
            if (null != select) {
              point.put("select", select);
            }
            points.add(point);
          }
        }
        Map<String, Object> opout = new LinkedHashMap<>();
        opout.put("points", points);
        ops.put(opname, opout);
      }

      Map<String, Object> entout = new LinkedHashMap<>();
      entout.put("fields", fields);
      entout.put("ops", ops);
      entities.put(ename, entout);
    }

    // Design 8.5: the features list gains `options` and `transport`, because
    // it was throwing away what the SDK already embeds.
    // `config.feature[name].options` is the feature's own declared key set
    // WITH TYPED DEFAULTS, which is the schema design 8.5 validates
    // against, and `transport` is the role design 8.4 orders by.
    //
    // Both are already inside the SDK; the descriptor stops discarding
    // them. ADDITIVE, so descriptor v1 consumers are unaffected and the
    // `descriptor` corpus section still passes unchanged.
    //
    // `transport` is CARRIED rather than inferred: the obvious signal, an
    // empty `hook: {}`, is wrong for station, which both wraps AND
    // dispatches hooks. Until sdkgen emits it, the design 8.4 role checks
    // degrade to nothing rather than guessing.
    List<Object> features = new ArrayList<>();
    Map<String, Object> fdefs = asmap(getprop(config, "feature"));
    Map<String, Object> factive = asmap(activeFeatures);
    for (String fname : new TreeMap<>(fdefs).keySet()) {
      Map<String, Object> fdef = asmap(fdefs.get(fname));
      Map<String, Object> feature = new LinkedHashMap<>();
      feature.put("name", fname);
      feature.put("active", Boolean.TRUE.equals(getprop(factive.get(fname), "active")));
      if (fdef.get("options") instanceof Map) {
        feature.put("options", fdef.get("options"));
      }
      Object transport = fdef.get("transport");
      if (null != transport && !"".equals(String.valueOf(transport))) {
        feature.put("transport", String.valueOf(transport));
      }
      features.add(feature);
    }

    Map<String, Object> descriptor = new LinkedHashMap<>();
    descriptor.put("station", 1);
    descriptor.put("name", name);
    descriptor.put("slug", slug);
    descriptor.put("envtoken", envtoken(slug));
    descriptor.put("version", version);
    descriptor.put("target", target);
    descriptor.put("base", textor(options.get("base"), ""));
    descriptor.put("server", server);
    descriptor.put("auth", auth);
    descriptor.put("entities", entities);
    descriptor.put("features", features);

    return new Normalized(descriptor, warnings);
  }

  /**
   * Canonical serialization (design 4): UTF-8, object keys sorted
   * bytewise, no insignificant whitespace, minimal JSON escaping. The
   * proxy dedupes registrations by a hash of this, so every language must
   * produce identical bytes - the `canonical-serialize` corpus section
   * carries the adversarial cases.
   */
  public static String canonicalSerialize(Object value) {
    StringBuilder out = new StringBuilder();
    serialize(value, out);
    return out.toString();
  }

  private static void serialize(Object value, StringBuilder out) {
    if (null == value) {
      out.append("null");
      return;
    }
    if (value instanceof Boolean) {
      out.append(value);
      return;
    }
    if (value instanceof Number) {
      out.append(numstr((Number) value));
      return;
    }
    if (value instanceof String) {
      quote((String) value, out);
      return;
    }
    if (value instanceof List) {
      out.append('[');
      List<Object> list = (List<Object>) value;
      for (int index = 0; index < list.size(); index++) {
        if (0 < index) {
          out.append(',');
        }
        serialize(list.get(index), out);
      }
      out.append(']');
      return;
    }
    if (value instanceof Map) {
      Map<String, Object> map = (Map<String, Object>) value;
      List<String> keys = new ArrayList<>(map.keySet());
      // Bytewise sort: compare UTF-8 byte sequences, not UTF-16 code units.
      keys.sort(Descriptor::compareUtf8);
      out.append('{');
      boolean first = true;
      for (String key : keys) {
        if (!first) {
          out.append(',');
        }
        first = false;
        quote(key, out);
        out.append(':');
        serialize(map.get(key), out);
      }
      out.append('}');
      return;
    }
    out.append("null");
  }

  // Integral numbers print without a decimal point or exponent, matching
  // the canonical JSON.stringify behaviour (2^53-1 stays exact).
  static String numstr(Number value) {
    double d = value.doubleValue();
    if (d == Math.rint(d) && !Double.isInfinite(d)
        && Long.MIN_VALUE <= d && d <= Long.MAX_VALUE) {
      return String.valueOf((long) d);
    }
    return String.valueOf(d);
  }

  // Minimal JSON escaping: quote, backslash, and control characters only;
  // everything else (non-ASCII included) passes through as UTF-8.
  static void quote(String text, StringBuilder out) {
    out.append('"');
    for (int index = 0; index < text.length(); index++) {
      char c = text.charAt(index);
      switch (c) {
        case '"':
          out.append("\\\"");
          break;
        case '\\':
          out.append("\\\\");
          break;
        case '\b':
          out.append("\\b");
          break;
        case '\f':
          out.append("\\f");
          break;
        case '\n':
          out.append("\\n");
          break;
        case '\r':
          out.append("\\r");
          break;
        case '\t':
          out.append("\\t");
          break;
        default:
          if (c < 0x20) {
            out.append(String.format("\\u%04x", (int) c));
          } else {
            out.append(c);
          }
      }
    }
    out.append('"');
  }

  static int compareUtf8(String a, String b) {
    // Unsigned: a UTF-8 lead byte (0x80+) must sort AFTER ASCII, and Java
    // bytes are signed.
    return Arrays.compareUnsigned(
        a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8));
  }

  // --- small shared helpers (map-shaped data, sekreto style) ---

  public static Map<String, Object> asmap(Object val) {
    if (val instanceof Map) {
      return (Map<String, Object>) val;
    }
    return new LinkedHashMap<>();
  }

  public static Object getprop(Object val, String key) {
    if (val instanceof Map) {
      return ((Map<String, Object>) val).get(key);
    }
    return null;
  }

  static String textor(Object val, String alt) {
    if (val instanceof String && !((String) val).isEmpty()) {
      return (String) val;
    }
    return alt;
  }
}
