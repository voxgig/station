// Feature management (station design 8): the three-level merge, the
// constraint-and-band resolver, and the descriptor-derived checker.
//
// The resolver is written to voxgig/plugin's 7 semantics so plugin can
// extract it - this is one of the pieces the joint plan means by "station
// builds natively to plugin's semantics".
//
// A port of typescript/src/feature.ts, which is canonical.

package com.voxgig.station;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

@SuppressWarnings({"unchecked"})
public final class Feature {

  private Feature() {}

  // -------------------------------------------------------------------
  // design 8.3 - the merge
  // -------------------------------------------------------------------

  /**
   * Reserved on a feature entry: not options, and never passed through to
   * the SDK's own option map.
   */
  public static final List<String> RESERVED_KEYS = List.of("active", "order");

  /**
   * Two-level and NO DEEPER: per feature name, then per option key.
   *
   * <p>`feature` is the ONE key where design 3.3's shallow-per-key rule is
   * wrong: composition is the entire point, a fleet default plus a
   * per-instance tweak. A map-valued OPTION replaces wholesale, which is
   * the depth boundary - what `{"$MERGE": {"deep": 2}}` states, and what a
   * port defaulting to a deep merge would silently get wrong.
   *
   * <p>NO DEFAULTS ARE SYNTHESIZED HERE - the caller passes RAW blocks. An
   * entry mentioned at one level with only a tuning key must NOT
   * synthesize `active` and switch on a feature a broader level turned
   * off. That is the design 3.3 defect one level down.
   */
  public static Map<String, Object> mergefeatures(List<Object> sources) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Object src : sources) {
      if (!(src instanceof Map)) {
        continue;
      }
      for (Map.Entry<String, Object> se : ((Map<String, Object>) src).entrySet()) {
        Object entry = se.getValue();
        if (!(entry instanceof Map)) {
          out.put(se.getKey(), entry);
          continue;
        }
        // Per option key, and NOT deeper.
        Object prior = out.get(se.getKey());
        Map<String, Object> merged = new LinkedHashMap<>();
        if (prior instanceof Map) {
          merged.putAll((Map<String, Object>) prior);
        }
        merged.putAll((Map<String, Object>) entry);
        out.put(se.getKey(), merged);
      }
    }
    return out;
  }

  /**
   * The six sources for one instance, in design 3.3's order extended by
   * the profile level:
   *
   * <pre>
   *   1 base.feature             4 overlay.feature
   *   2 base.api[api].feature    5 overlay.api[api].feature
   *   3 base.sdk[ref].feature    6 overlay.sdk[ref].feature
   * </pre>
   *
   * <p>PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a
   * profile the narrower block wins - the same principle as design 3.3,
   * one level down. Assembled here rather than at the call site so the
   * order lives in exactly one place; an absent level contributes nothing.
   */
  public static List<Object> featuresources(Object base, Object overlay,
      String api, String ref) {
    List<Object> out = new ArrayList<>();
    out.add(Descriptor.getprop(base, "feature"));
    out.add(Descriptor.getprop(
        Descriptor.getprop(Descriptor.getprop(base, "api"), api), "feature"));
    out.add(Descriptor.getprop(
        Descriptor.getprop(Descriptor.getprop(base, "sdk"), ref), "feature"));
    out.add(Descriptor.getprop(overlay, "feature"));
    out.add(Descriptor.getprop(
        Descriptor.getprop(Descriptor.getprop(overlay, "api"), api), "feature"));
    out.add(Descriptor.getprop(
        Descriptor.getprop(Descriptor.getprop(overlay, "sdk"), ref), "feature"));
    return out;
  }

  // -------------------------------------------------------------------
  // design 8.4 - activation and order
  // -------------------------------------------------------------------

  // `test` substitutes the base transport, so it takes the innermost band;
  // `station` sits immediately outside it, pinned; everything else is band
  // 0, outside station.
  //
  // THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
  // than as a special case: a project that writes no `order` anywhere sees
  // exactly today's nesting, and sdkgen's two makeOptions special cases
  // become two band values rather than two branches.
  public static final int BAND_DEFAULT = 0;
  public static final int BAND_STATION = 100;
  public static final int BAND_TEST = 200;

  /** Higher is further IN. */
  public static int defaultband(String name) {
    if ("test".equals(name)) {
      return BAND_TEST;
    }
    if ("station".equals(name)) {
      return BAND_STATION;
    }
    return BAND_DEFAULT;
  }

  /** One row of the resolved order, OUTERMOST FIRST. */
  public static final class Ordered {
    public final String name;
    public final int band;
    public final Object entry;

    Ordered(String name, int band, Object entry) {
      this.name = name;
      this.band = band;
      this.entry = entry;
    }
  }

  /**
   * Resolve the activation order: constraints, then bands, then the
   * feature's DECLARATION POSITION in the merged map.
   *
   * <p>`before`/`after` take a feature name or a list of them and are
   * SATISFIED VACUOUSLY when the named feature is absent - `after: 'test'`
   * loads fine in a project with no test feature, which is sdkgen's
   * `__after__` behaviour kept rather than reinvented.
   *
   * <p>Constraints beat bands; bands break ties no constraint decides;
   * remaining ties break by declaration position, so the result is a stable
   * topological sort with no alphabetical accident in it.
   *
   * <p>Returns OUTERMOST FIRST, which is the array form the constructor
   * takes and the direction plugin's chain composes in. Java keeps the
   * declaration order for free: omni and sekreto both parse JSON objects
   * into LinkedHashMap, so `merged`'s key order IS the authored order.
   */
  public static List<Ordered> resolveorder(Map<String, Object> merged) {
    List<String> names = new ArrayList<>();
    for (Map.Entry<String, Object> e : merged.entrySet()) {
      if (active(e.getValue())) {
        names.add(e.getKey());
      }
    }

    Map<String, Integer> pos = new LinkedHashMap<>();
    for (int index = 0; index < names.size(); index++) {
      pos.put(names.get(index), index);
    }

    Map<String, Integer> band = new LinkedHashMap<>();
    for (String name : names) {
      Object order = Descriptor.getprop(merged.get(name), "order");
      Object raw = Descriptor.getprop(order, "band");
      band.put(name, raw instanceof Number
          ? ((Number) raw).intValue() : defaultband(name));
    }

    // edges: from OUTER to INNER. `after: X` means "further in than X".
    Map<String, Set<String>> inner = new LinkedHashMap<>();
    for (String name : names) {
      inner.put(name, new LinkedHashSet<>());
    }

    for (String name : names) {
      Object order = Descriptor.getprop(merged.get(name), "order");
      if (!(order instanceof Map)) {
        continue;
      }
      // Vacuous when absent: an unknown name is not an error here.
      for (String other : listof(Descriptor.getprop(order, "after"))) {
        if (inner.containsKey(other)) {
          inner.get(other).add(name);
        }
      }
      for (String other : listof(Descriptor.getprop(order, "before"))) {
        if (inner.containsKey(other)) {
          inner.get(name).add(other);
        }
      }
    }

    Map<String, Integer> indeg = new LinkedHashMap<>();
    for (String name : names) {
      indeg.put(name, 0);
    }
    for (String name : names) {
      for (String to : inner.get(name)) {
        indeg.put(to, indeg.get(to) + 1);
      }
    }

    // Kahn, picking the LOWEST BAND first (outermost), then declaration
    // position - so ties break the same way in every port.
    List<String> ready = new ArrayList<>();
    for (String name : names) {
      if (0 == indeg.get(name)) {
        ready.add(name);
      }
    }

    List<Ordered> out = new ArrayList<>();
    while (!ready.isEmpty()) {
      ready.sort((a, b) -> {
        int d = band.get(a) - band.get(b);
        return 0 != d ? d : pos.get(a) - pos.get(b);
      });
      String name = ready.remove(0);
      out.add(new Ordered(name, band.get(name), merged.get(name)));
      for (String to : inner.get(name)) {
        indeg.put(to, indeg.get(to) - 1);
        if (0 == indeg.get(to)) {
          ready.add(to);
        }
      }
    }

    if (out.size() != names.size()) {
      TreeSet<String> stuck = new TreeSet<>(names);
      for (Ordered one : out) {
        stuck.remove(one.name);
      }
      throw new StationError("station_feature_order",
          "feature ordering constraints form a cycle among ["
              + String.join(", ", stuck) + "]");
    }

    return out;
  }

  // `before`/`after` accept a single string or a list of them, stringified.
  private static List<String> listof(Object val) {
    List<String> out = new ArrayList<>();
    if (null == val) {
      return out;
    }
    if (val instanceof List) {
      for (Object one : (List<Object>) val) {
        out.add(String.valueOf(one));
      }
      return out;
    }
    out.add(String.valueOf(val));
    return out;
  }

  /**
   * A feature named in the config is one you are ASKING for, so an entry
   * with no `active` is active. A non-map entry is active unless it is
   * exactly boolean false.
   */
  public static boolean active(Object entry) {
    if (!(entry instanceof Map)) {
      return !Boolean.FALSE.equals(entry);
    }
    return !Boolean.FALSE.equals(((Map<String, Object>) entry).get("active"));
  }

  /** The names of an ordered list, outermost first. */
  public static List<String> featureNames(List<Ordered> ordered) {
    List<String> out = new ArrayList<>();
    for (Ordered one : ordered) {
      out.add(one.name);
    }
    return out;
  }

  /**
   * Station's own position is PINNED and not orderable (design 8.4): an
   * order that moves `station` away from immediately-outside-the-base is
   * REJECTED, not honoured.
   *
   * <p>THE SPELLING OF THE PIN MATTERS. A chain composes with the FIRST
   * binding OUTERMOST, so a pin written in sort terms - "station first" -
   * would place every other wrapper between the adapter and the base: the
   * exact inversion of the invariant, and one that would leave station's
   * wire-truth events observing the wrong boundary while still looking
   * ordered. The pin is INNERMOST.
   */
  public static void checkpin(List<Ordered> ordered) {
    int at = indexOf(ordered, "station");
    if (-1 == at) {
      return;
    }
    int base = indexOf(ordered, "test");
    // station must be the innermost wrapper: last, or immediately outside
    // the base-transport feature when one is active.
    int want = -1 == base ? ordered.size() - 1 : base - 1;
    if (at != want) {
      throw new StationError("station_feature_order",
          "an ordering would move `station` away from immediately outside "
              + "the base transport; its position is pinned innermost and is "
              + "not orderable (8.4)");
    }
  }

  private static int indexOf(List<Ordered> ordered, String name) {
    for (int index = 0; index < ordered.size(); index++) {
      if (name.equals(ordered.get(index).name)) {
        return index;
      }
    }
    return -1;
  }

  /**
   * Compose the ordered rows into the ARRAY FORM the generated constructor
   * already accepts: `{name, active: true}` plus every key of the entry
   * except the reserved ones. No new seam.
   */
  public static List<Map<String, Object>> composefeatures(List<Ordered> ordered) {
    List<Map<String, Object>> out = new ArrayList<>();
    for (Ordered one : ordered) {
      Map<String, Object> entry = Descriptor.asmap(one.entry);
      Map<String, Object> row = new LinkedHashMap<>();
      row.put("name", one.name);
      row.put("active", Boolean.TRUE);
      for (Map.Entry<String, Object> e : entry.entrySet()) {
        if (RESERVED_KEYS.contains(e.getKey())) {
          continue;
        }
        row.put(e.getKey(), e.getValue());
      }
      out.add(row);
    }
    return out;
  }

  // -------------------------------------------------------------------
  // design 8.5 - the checker, derived from the descriptor
  // -------------------------------------------------------------------

  /** One fault from the design 8.5 pass. COLLECTED, never thrown here. */
  public static final class Fault {
    public final String code;
    public final String feature;
    public final String key;
    public final String message;

    Fault(String code, String feature, String key, String message) {
      this.code = code;
      this.feature = feature;
      this.key = key;
      this.message = message;
    }
  }

  /**
   * Check a merged feature map against the SDK'S OWN DECLARATION.
   *
   * <p>The schema arrives with the FACTORY rather than with a live client
   * (design 6.2), so this needs no construction and no network - which is
   * what lets check() run it for every instance in CI.
   *
   * <p>Derived from the descriptor, NEVER hand-written, so it cannot drift:
   * when a feature gains an option, the next regeneration teaches station
   * about it with no station change.
   *
   * <p>SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED
   * ONLY, and that limit is real and deliberate: an empty list default says
   * nothing reliable about its element type and a nested map default says
   * nothing about its value shapes.
   */
  public static List<Fault> checkfeatures(Map<String, Object> merged,
      Object descriptor) {
    List<Fault> faults = new ArrayList<>();

    Map<String, Object> byname = new LinkedHashMap<>();
    Object declared = Descriptor.getprop(descriptor, "features");
    if (declared instanceof List) {
      for (Object row : (List<Object>) declared) {
        Object name = Descriptor.getprop(row, "name");
        if (null != name) {
          byname.put(String.valueOf(name), row);
        }
      }
    }

    for (String name : new TreeSet<>(merged.keySet())) {
      Object spec = byname.get(name);
      if (null == spec) {
        faults.add(new Fault("station_feature_unknown", name, null,
            "the SDK has no feature \"" + name + "\"; it declares ["
                + String.join(", ", new TreeSet<>(byname.keySet())) + "]"));
        continue;
      }

      Object entry = merged.get(name);
      if (!(entry instanceof Map)) {
        continue;
      }
      Map<String, Object> defaults =
          Descriptor.asmap(Descriptor.getprop(spec, "options"));

      for (String key : new TreeSet<>(((Map<String, Object>) entry).keySet())) {
        if (RESERVED_KEYS.contains(key)) {
          continue;
        }

        if (!defaults.containsKey(key)) {
          // THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is accepted and
          // silently ignored today, because the SDK's own feature spec is
          // `$OPEN` per feature so the SDK cannot catch it and nothing else
          // looks.
          faults.add(new Fault("station_feature_option", name, key,
              "feature \"" + name + "\" declares no option \"" + key
                  + "\"; it declares ["
                  + String.join(", ", new TreeSet<>(defaults.keySet())) + "]"));
          continue;
        }

        String want = kindof(defaults.get(key));
        String got = kindof(((Map<String, Object>) entry).get(key));
        if (!want.equals(got)) {
          faults.add(new Fault("station_feature_option", name, key,
              "feature \"" + name + "\" option \"" + key + "\" expects " + want
                  + ", but found " + got + ": "
                  + Descriptor.canonicalSerialize(
                      ((Map<String, Object>) entry).get(key))));
        }
      }
    }

    return faults;
  }

  /** The joined messages of a fault list - what the raised error carries. */
  public static String faultMessages(List<Fault> faults) {
    List<String> out = new ArrayList<>();
    for (Fault fault : faults) {
      out.add(fault.message);
    }
    return String.join("; ", out);
  }

  /**
   * The FEATURE kindof. NOT the same function as Shape.kindof, and they
   * must not be unified: this one speaks the descriptor's spellings ("map",
   * "number"), the shape one speaks struct's ("object", "integer").
   */
  static String kindof(Object val) {
    if (null == val) {
      return "null";
    }
    if (val instanceof List) {
      return "list";
    }
    if (val instanceof Number) {
      return "number";
    }
    if (val instanceof Map) {
      return "map";
    }
    if (val instanceof Boolean) {
      return "boolean";
    }
    if (val instanceof String) {
      return "string";
    }
    return val.getClass().getSimpleName().toLowerCase();
  }
}
