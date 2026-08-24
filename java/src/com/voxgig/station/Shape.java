// The config grammar, as data (station design 4).
//
// TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
//
// struct drops the unexpected-key check for a map whose spec node ends up
// EMPTY - "an empty spec object means the object can be open". An optional
// key is `['$ONE','$NIL', spec]`, and when the data does not carry that
// key the validator REMOVES it from the spec node. So a block whose keys
// are all optional degenerates into an open map exactly when the data has
// none of them, and `{"solar": {"bass": 1}}` validates clean - the one
// property the whole exercise is for, silently absent in the one case
// that matters.
//
// So: normalizeConfig materializes every documented default, and
// validateConfig then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
// After normalization every container is present, so the shape can
// require them, so unexpected-key detection is live at every level and
// every error names its path.
//
// A port of typescript/src/shape.ts, which is canonical.

package com.voxgig.station;

import com.voxgig.sekreto.Json;
import com.voxgig.sekreto.Sekreto;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.function.Supplier;
import java.util.regex.Pattern;

import voxgig.struct.Struct;

@SuppressWarnings({"unchecked"})
public final class Shape {

  private Shape() {}

  // -------------------------------------------------------------------
  // The defaults table - ONE table, two callers
  // -------------------------------------------------------------------

  /**
   * Profile-level containers. Safe to materialize early either way: they
   * are containers, and a missing one merges as empty regardless. Built
   * per call, so a caller cannot alias a shared default into a config.
   */
  public static Map<String, Supplier<Object>> profileDefaults() {
    Map<String, Supplier<Object>> out = new LinkedHashMap<>();
    out.put("secrets", () -> {
      Map<String, Object> env = new LinkedHashMap<>();
      env.put("kind", "env");
      List<Object> providers = new ArrayList<>();
      providers.add(env);
      Map<String, Object> secrets = new LinkedHashMap<>();
      secrets.put("providers", providers);
      return secrets;
    });
    out.put("api", LinkedHashMap::new);
    out.put("sdk", LinkedHashMap::new);
    out.put("feature", LinkedHashMap::new);
    return out;
  }

  /**
   * Block-level. `feature` is a container and safe early.
   *
   * <p>`active` IS NOT, and that is the whole timing rule: a default
   * synthesized into an OVERLAY block overwrites the base's real value and
   * silently reactivates an integration the base deliberately barred
   * (design 3.3). So the two consumers read this same table at different
   * moments - validateConfig BEFORE, applied to every block, because a
   * block with no present keys is an open map; the profile resolver
   * AFTER, applied to the merged instance, because an absent key must stay
   * absent through the merge.
   */
  public static Map<String, Supplier<Object>> blockDefaults() {
    Map<String, Supplier<Object>> out = new LinkedHashMap<>();
    out.put("active", () -> Boolean.TRUE);
    out.put("feature", LinkedHashMap::new);
    return out;
  }

  /**
   * The one block key carrying the timing rule. NAMED rather than
   * inferred, so a reader does not have to work out which of the two it is,
   * and so a port can assert it.
   */
  public static final List<String> MERGE_SENSITIVE = List.of("active");

  // -------------------------------------------------------------------
  // normalizeConfig
  // -------------------------------------------------------------------

  /**
   * Materialize every documented default, DEFENSIVELY: a node that is not
   * the kind it expects is left alone for validate to reject with a proper
   * message. Pure data-in / data-out, which is what makes it portable to
   * sixteen languages and expressible in the corpus. MUST NOT MUTATE THE
   * INPUT - every map is copied before anything is written into it.
   *
   * <p>THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE.
   * `resolveProfile` keeps reading the RAW config.
   */
  public static Object normalizeConfig(Object raw) {
    if (!ismap(raw)) {
      return raw;
    }
    Map<String, Object> out = new LinkedHashMap<>((Map<String, Object>) raw);

    if (!out.containsKey("station")) {
      out.put("station", 1);
    }
    if (!out.containsKey("profiles")) {
      out.put("profiles", new LinkedHashMap<String, Object>());
    }
    // Not a map: leave it for validate to reject BY PATH.
    if (!ismap(out.get("profiles"))) {
      return out;
    }

    Map<String, Supplier<Object>> pdefaults = profileDefaults();
    Map<String, Supplier<Object>> bdefaults = blockDefaults();

    Map<String, Object> profiles = new LinkedHashMap<>();
    for (Map.Entry<String, Object> pe
        : ((Map<String, Object>) out.get("profiles")).entrySet()) {
      if (!ismap(pe.getValue())) {
        profiles.put(pe.getKey(), pe.getValue());
        continue;
      }
      Map<String, Object> prof =
          new LinkedHashMap<>((Map<String, Object>) pe.getValue());

      for (Map.Entry<String, Supplier<Object>> d : pdefaults.entrySet()) {
        if (!prof.containsKey(d.getKey())) {
          prof.put(d.getKey(), d.getValue().get());
        }
      }
      // A `secrets` block written WITHOUT `providers` still gets the
      // documented chain.
      if (ismap(prof.get("secrets"))
          && !((Map<String, Object>) prof.get("secrets")).containsKey("providers")) {
        Map<String, Object> secrets =
            new LinkedHashMap<>((Map<String, Object>) prof.get("secrets"));
        secrets.put("providers", getprop(pdefaults.get("secrets").get(), "providers"));
        prof.put("secrets", secrets);
      }
      prof.put("feature", normfeatures(prof.get("feature")));

      for (String bkey : new String[] { "api", "sdk" }) {
        if (!ismap(prof.get(bkey))) {
          continue;
        }
        Map<String, Object> blocks = new LinkedHashMap<>();
        for (Map.Entry<String, Object> be
            : ((Map<String, Object>) prof.get(bkey)).entrySet()) {
          if (!ismap(be.getValue())) {
            blocks.put(be.getKey(), be.getValue());
            continue;
          }
          Map<String, Object> block =
              new LinkedHashMap<>((Map<String, Object>) be.getValue());
          for (Map.Entry<String, Supplier<Object>> d : bdefaults.entrySet()) {
            if (!block.containsKey(d.getKey())) {
              block.put(d.getKey(), d.getValue().get());
            }
          }
          block.put("feature", normfeatures(block.get("feature")));
          blocks.put(be.getKey(), block);
        }
        prof.put(bkey, blocks);
      }

      profiles.put(pe.getKey(), prof);
    }
    out.put("profiles", profiles);
    return out;
  }

  /**
   * Per feature entry, at every level: `active` -> true.
   *
   * <p>A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
   * own default is `active: false` for all but `log`, and
   * `{"retry": {"retries": 3}}` plainly means "retry, with three
   * attempts". It also keeps the feature map closed, for the same reason
   * every other block needs one present key.
   *
   * <p>Defensive like the rest: a non-map is returned untouched, for
   * validate to reject by path.
   */
  private static Object normfeatures(Object f) {
    if (!ismap(f)) {
      return f;
    }
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map.Entry<String, Object> fe : ((Map<String, Object>) f).entrySet()) {
      Object entry = fe.getValue();
      if (ismap(entry) && !((Map<String, Object>) entry).containsKey("active")) {
        Map<String, Object> copy = new LinkedHashMap<>((Map<String, Object>) entry);
        copy.put("active", Boolean.TRUE);
        out.put(fe.getKey(), copy);
      } else {
        out.put(fe.getKey(), entry);
      }
    }
    return out;
  }

  // -------------------------------------------------------------------
  // validateConfig
  // -------------------------------------------------------------------

  // `spec/config-shape.json`, design 4.3 verbatim - the artifact every
  // port reads. A jar ships compiled and cannot see `spec/` at run time,
  // and validateConfig runs at open() rather than only under test, so this
  // port carries a MIRROR beside the class (config-shape.json on the
  // classpath, copied by `make sync-shape`). StationTest deep-compares the
  // mirror with spec/config-shape.json and fails on drift - a mirror that
  // can drift is a mirror that will.
  private static Object shapeSource = null;

  /**
   * A FRESH DEEP COPY of the shape on every call. struct's validate
   * CONSUMES the spec it walks - it deletes satisfied `$ONE` branches as it
   * goes - so handing it one parsed constant twice would validate the
   * second config against a spec the first had already eaten.
   */
  public static synchronized Object configShape() {
    if (null == shapeSource) {
      shapeSource = Json.parse(resource("config-shape.json"));
    }
    return Struct.clone(shapeSource);
  }

  private static String resource(String name) {
    try (InputStream in = Shape.class.getResourceAsStream(name)) {
      if (null == in) {
        throw new StationError("station_config_invalid",
            "station: the config shape mirror is missing from the classpath: "
                + name + " - run `make sync-shape`");
      }
      ByteArrayOutputStream buf = new ByteArrayOutputStream();
      byte[] chunk = new byte[8192];
      int read;
      while (0 < (read = in.read(chunk))) {
        buf.write(chunk, 0, read);
      }
      return new String(buf.toByteArray(), StandardCharsets.UTF_8);
    } catch (IOException err) {
      throw new StationError("station_config_invalid",
          "station: cannot read the config shape mirror: " + err.getMessage());
    }
  }

  // Credential-shaped keys (design 5.2). `secret` is here AND is the one
  // exempt key - see secretvalue below; a blanket deny would reject the
  // very mechanism that keeps values out of the file.
  private static final List<String> CREDENTIAL_KEYS = List.of(
      "apikey", "auth", "authorization", "token",
      "secret", "password", "credential", "bearer");

  // The suffix rule catches `access_key`, `X-Api-Token` and friends in one
  // rule rather than a growing list of spellings.
  private static final List<String> CREDENTIAL_SUFFIX = List.of(
      "_KEY", "_TOKEN", "_SECRET", "_PASSWORD");

  // Design 5.2's backstop, stated as one rule rather than as a grammar.
  // `validname()` is a NAME grammar, not a credential filter: it rejects
  // uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
  // credential formats - but a lowercase hex token passes it cleanly. A
  // character class cannot tell a name from a secret.
  //
  // Derived names break on every separator (`voxgig_solardemo.apikey` runs
  // 6/9/6) and a hand-written name for a human to read does too; a
  // 24-character unbroken run is not a name anybody writes. Note this is a
  // RUN bound, not a LENGTH bound: `acme_internal_billing_service.apikey`
  // is 36 characters and passes, which is the false positive a naive
  // length bound would produce.
  private static final int RUN_BOUND = 24;
  private static final Pattern UNBROKEN_RUN =
      Pattern.compile("[A-Za-z0-9]{" + RUN_BOUND + ",}");

  private static final Pattern SCHEME = Pattern.compile("^[a-zA-Z][a-zA-Z0-9+.-]*://");

  private static final List<String> BUDGET_KEYS = List.of("concurrency", "rps");

  /**
   * Run the shape, then the design 4.4 and 5.2 scans. Raises
   * station_config_invalid with EVERY error at once - an eighteen-instance
   * config that touches three of them must not die because the eighteenth
   * has a typo'd package name - then the reserved and secret scans.
   *
   * <p>The design 4.4 workarounds are merged into the SAME throw as
   * struct's own errors: a struct new enough to reject a first-element gap
   * itself reports a DIFFERENT spelling ("to be one of ..."), and the
   * corpus pins the explicit one - so the pinned message is produced here
   * either way, and behaviour is identical whatever struct version
   * resolves.
   *
   * <p>Takes the NORMALIZED form. Handing it a raw config is the mistake
   * design 4.2 exists to prevent, so every caller goes through
   * normalizeConfig first.
   */
  public static Object validateConfig(Object normalized) {
    List<Object> errs = new ArrayList<>();
    Map<String, Object> options = new LinkedHashMap<>();
    options.put("errs", errs);
    // struct's `$EXACT` compares with equals, and JSON has one number type
    // where Java has six: the shape's `1` is whatever the shape's parser
    // produced, and a config written in Java code carries whatever the
    // caller wrote. So the VALIDATOR sees a number-normalized deep copy -
    // a copy, and only the validator sees it.
    Struct.validate(numbers(normalized), configShape(), options);

    Scan scan = scanConfig(normalized);

    if (!errs.isEmpty() || !scan.invalid.isEmpty()) {
      List<String> all = new ArrayList<>();
      for (Object err : errs) {
        all.add(transformnames(String.valueOf(err)));
      }
      all.addAll(scan.invalid);
      throw new StationError("station_config_invalid",
          String.join("; ", all) + renamehint(normalized));
    }
    if (!scan.reserved.isEmpty()) {
      throw new StationError("station_feature_reserved",
          String.join("; ", scan.reserved));
    }
    if (!scan.secrets.isEmpty()) {
      throw new StationError("station_config_secret",
          String.join("; ", scan.secrets));
    }
    return normalized;
  }

  // A struct-port divergence, narrowed here rather than left to differ.
  //
  // The canonical struct lowers every transform-command marker in a `$ONE`
  // alternatives list by applying /`\$([A-Z]+)`/g GLOBALLY to the joined
  // description, so a NESTED marker reads `[exact,library]` and
  // `{write:boolean}`. struct's java port applies the same regex only when
  // an alternative is ITSELF a whole marker string, so a nested one comes
  // back as `[`$EXACT`,library]`. The corpus pins the canonical spelling,
  // and the config grammar is full of nested `$EXACT` and `$CHILD`
  // alternatives, so the same lowering is applied here to struct's
  // collected messages.
  //
  // Narrow on purpose: it rewrites nothing but a backticked `$NAME`
  // marker, which is struct's own vocabulary and never a value a config
  // carries. Filed upstream; this goes when struct's java port lands the
  // global replace, and until then the java port reports what every other
  // port reports.
  private static final Pattern TRANSFORM_NAME = Pattern.compile("`\\$([A-Z]+)`");

  private static String transformnames(String message) {
    java.util.regex.Matcher matcher = TRANSFORM_NAME.matcher(message);
    StringBuilder out = new StringBuilder();
    while (matcher.find()) {
      matcher.appendReplacement(out,
          java.util.regex.Matcher.quoteReplacement(
              matcher.group(1).toLowerCase()));
    }
    matcher.appendTail(out);
    return out.toString();
  }

  // Every Number to a double, so `$EXACT` sees one numeric type. Lists and
  // maps are rebuilt; every other value passes through by reference.
  private static Object numbers(Object node) {
    if (node instanceof Number) {
      return ((Number) node).doubleValue();
    }
    if (node instanceof List) {
      List<Object> out = new ArrayList<>();
      for (Object item : (List<Object>) node) {
        out.add(numbers(item));
      }
      return out;
    }
    if (node instanceof Map) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> e : ((Map<String, Object>) node).entrySet()) {
        out.put(e.getKey(), numbers(e.getValue()));
      }
      return out;
    }
    return node;
  }

  /**
   * `plugin` is REMOVED, not aliased (design 3.4) - a deprecated alias
   * would be a second grammar for one concept in sixteen ports. The shape
   * already rejects it as an unexpected key; this says WHAT TO RENAME,
   * because "unexpected key: plugin" alone does not, and the migration for
   * a single-instance project is exactly this one rename.
   */
  private static String renamehint(Object cfg) {
    Object profiles = getprop(cfg, "profiles");
    if (!ismap(profiles)) {
      return "";
    }
    List<String> hit = new ArrayList<>();
    for (Map.Entry<String, Object> pe : ((Map<String, Object>) profiles).entrySet()) {
      if (ismap(pe.getValue())
          && ((Map<String, Object>) pe.getValue()).containsKey("plugin")) {
        hit.add("profiles." + pe.getKey());
      }
    }
    if (hit.isEmpty()) {
      return "";
    }
    return "; rename `plugin` to `sdk` in " + String.join(", ", hit)
        + " - the keys are unchanged, an untagged ref IS an api slug (3.4)";
  }

  // The three collections the scans fill. COLLECT, never throw -
  // validateConfig owns the throw order.
  private static final class Scan {
    final List<String> secrets = new ArrayList<>();
    final List<String> reserved = new ArrayList<>();
    final List<String> invalid = new ArrayList<>();
  }

  /**
   * The design 5.2 scans, over the parts of the grammar that hold
   * arbitrary data. Everything else is closed by construction and needs no
   * scan.
   *
   * <p>IMPORTANTLY, `profiles.p.secrets.providers` IS NOT SCANNED: a
   * provider block legitimately carries an `auth` sub-map
   * ({method, role}), and `config#twenty-sdk-fleet` passes only because
   * the scan does not reach there.
   */
  private static Scan scanConfig(Object cfg) {
    Scan scan = new Scan();

    Object profiles = getprop(cfg, "profiles");
    if (!ismap(profiles)) {
      return scan;
    }

    for (Map.Entry<String, Object> pe : ((Map<String, Object>) profiles).entrySet()) {
      if (!ismap(pe.getValue())) {
        continue;
      }
      Map<String, Object> prof = (Map<String, Object>) pe.getValue();
      String ppath = "profiles." + pe.getKey();

      checkfeatures(prof.get("feature"), ppath + ".feature", scan);

      for (String bkey : new String[] { "api", "sdk" }) {
        if (!ismap(prof.get(bkey))) {
          continue;
        }
        for (Map.Entry<String, Object> be
            : ((Map<String, Object>) prof.get(bkey)).entrySet()) {
          if (!ismap(be.getValue())) {
            continue;
          }
          Map<String, Object> block = (Map<String, Object>) be.getValue();
          String bpath = ppath + "." + bkey + "." + be.getKey();

          // The block's own `secret` holds a NAME. resolveProfile checks it
          // again per instance (station_secret_name); this catches it at
          // open(), for the whole file at once.
          if (block.containsKey("secret")) {
            secretvalue(block.get("secret"), bpath + ".secret", scan);
          }

          // `options` is passthrough to a generated constructor, so it is
          // the one place a value can hide.
          scan(block.get("options"), bpath + ".options", scan);
          checkfeatures(block.get("feature"), bpath + ".feature", scan);

          // Design 4.4's explicit checks, applied where the shape cannot
          // reach, raising the same code the shape would - and pinned in
          // the corpus so each workaround is removed deliberately when
          // struct is fixed rather than forgotten.
          checkpolicy(block.get("policy"), bpath + ".policy", scan);
        }
      }
    }

    return scan;
  }

  /**
   * A feature map at any level. `station` is reserved: station composes its
   * own wrap and a config that reconfigures it is asking for a state the
   * ordering rules cannot express (design 8.4). A config file that can
   * switch off the component reading it is not a surface, it is a trap.
   */
  private static void checkfeatures(Object f, String path, Scan scan) {
    if (!ismap(f)) {
      return;
    }
    for (Map.Entry<String, Object> fe : ((Map<String, Object>) f).entrySet()) {
      String fpath = path + "." + fe.getKey();
      if ("station".equals(fe.getKey())) {
        scan.reserved.add(path + ".station is reserved: station composes its own "
            + "wrap and it cannot be configured from station.json");
      }
      Object order = getprop(fe.getValue(), "order");
      if (ismap(order)) {
        firstelement(getprop(order, "before"), fpath + ".order.before", scan);
        firstelement(getprop(order, "after"), fpath + ".order.after", scan);
      }
      scan(fe.getValue(), fpath, scan);
    }
  }

  /**
   * The policy block's design 4.4 workarounds, in one place because they
   * are one class of gap: struct cannot check what its own defects hide.
   *
   * <ul>
   * <li>`hosts`, `allow.op` and `allow.method` are `$CHILD` string lists,
   *     so element 0 escapes the shape (see firstelement below).
   * <li>`budget` is a map whose keys are ALL optional scalars, and struct
   *     removes an unsatisfied optional key from the spec node - so
   *     `budget: {rp: 1}` degenerates the spec into an open map and the
   *     typo passes. `allow` does not have this problem (its `$CHILD` keys
   *     stay in the spec whether or not the data carries them), and
   *     neither does `policy` itself (`hosts` anchors it).
   * </ul>
   */
  private static void checkpolicy(Object policy, String path, Scan scan) {
    if (!ismap(policy)) {
      return;
    }

    firstelement(getprop(policy, "hosts"), path + ".hosts", scan);

    Object allow = getprop(policy, "allow");
    if (ismap(allow)) {
      firstelement(getprop(allow, "op"), path + ".allow.op", scan);
      firstelement(getprop(allow, "method"), path + ".allow.method", scan);
    }

    Object budget = getprop(policy, "budget");
    if (ismap(budget)) {
      TreeSet<String> unknown = new TreeSet<>();
      for (String key : ((Map<String, Object>) budget).keySet()) {
        if (!BUDGET_KEYS.contains(key)) {
          unknown.add(key);
        }
      }
      if (!unknown.isEmpty()) {
        scan.invalid.add("Unexpected keys at field " + path + ".budget: "
            + String.join(", ", unknown));
      }
    }
  }

  /**
   * Design 4.4: `$CHILD` in LIST mode DOES NOT VALIDATE ELEMENT 0.
   * Verified: `["a", 1]` fails at index 1, `[1]` passes, at any list
   * length. Filed upstream as voxgig/struct#113.
   *
   * <p>It reaches THREE string lists in this shape: `policy.hosts`, and the
   * per-feature `order.before` and `order.after`. Applied where the shape
   * cannot reach, raising the same code the shape would, and PINNED IN THE
   * CORPUS so the workaround is removed deliberately when struct is fixed
   * rather than forgotten.
   */
  private static void firstelement(Object list, String path, Scan scan) {
    if (!(list instanceof List) || ((List<Object>) list).isEmpty()) {
      return;
    }
    Object first = ((List<Object>) list).get(0);
    if (first instanceof String) {
      return;
    }
    scan.invalid.add("Expected field " + path + ".0 to be string, but found "
        + kindof(first) + ": " + json(first));
  }

  /**
   * RECURSIVE OVER EVERY NESTED MAP AND LIST, not just the top level - a
   * credential one level down is the case a top-level scan misses
   * (`config#options-scan-is-recursive` pins `options.deep.list.0.apikey`).
   */
  private static void scan(Object node, String path, Scan scan) {
    if (node instanceof List) {
      List<Object> list = (List<Object>) node;
      for (int index = 0; index < list.size(); index++) {
        scan(list.get(index), path + "." + index, scan);
      }
      return;
    }
    if (node instanceof String) {
      userinfo((String) node, path, scan);
      return;
    }
    if (!ismap(node)) {
      return;
    }

    for (Map.Entry<String, Object> e : ((Map<String, Object>) node).entrySet()) {
      String key = e.getKey();
      String kpath = path + "." + key;
      Object val = e.getValue();

      // Design 8.6: station owns feature composition, so an
      // `options.feature` in a declarative config is a second,
      // unreconciled ordering input - two representations of one setting
      // resolved differently by sixteen ports.
      if ("feature".equals(key)) {
        scan.reserved.add(kpath + " is reserved: configure features under the "
            + "block's own `feature` key, not through `options`");
        continue;
      }

      if ("secret".equals(key.toLowerCase())) {
        secretvalue(val, kpath, scan);
        continue;
      }

      if (credentialkey(key)) {
        scan.secrets.add(kpath + " is a credential-shaped key: station.json "
            + "holds secret NAMES, never values (5.2)");
        continue;
      }

      scan(val, kpath, scan);
    }
  }

  private static boolean credentialkey(String key) {
    String low = key.toLowerCase().replaceAll("[^a-z0-9]+", "");
    if (CREDENTIAL_KEYS.contains(low)) {
      return true;
    }
    String tok = Descriptor.envtoken(key);
    for (String suffix : CREDENTIAL_SUFFIX) {
      if (tok.endsWith(suffix)) {
        return true;
      }
    }
    return false;
  }

  /**
   * A `secret`-named key holds a NAME, and that exemption is not a loophole
   * - it is the whole design, since a blanket deny would reject the very
   * mechanism that keeps values out of the file. THREE checks, in this
   * order, first failure wins, and they live in the same handful of lines
   * precisely so a port cannot implement only the first and inherit the
   * gaps the others close.
   */
  private static void secretvalue(Object val, String path, Scan scan) {
    if (!(val instanceof String)) {
      scan.secrets.add(path + " must be a secret name (a string), but found "
          + kindof(val));
      return;
    }
    if (!Sekreto.validname(val)) {
      scan.secrets.add(path + " is not a valid sekreto name, so it cannot be a "
          + "name and must not be a value: " + json(val));
      return;
    }
    if (UNBROKEN_RUN.matcher((String) val).find()) {
      scan.secrets.add(path + " contains an unbroken alphanumeric run of "
          + RUN_BOUND + " or more characters, which is not a name anybody writes");
    }
  }

  /**
   * One rule about VALUES rather than keys, because the `proxy` feature
   * makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
   * failure is not an error - return silently.
   */
  private static void userinfo(String val, String path, Scan scan) {
    if (!SCHEME.matcher(val).find()) {
      return;
    }
    int at = val.indexOf("://");
    String rest = val.substring(at + 3);
    int end = rest.length();
    for (char stop : new char[] { '/', '?', '#' }) {
      int cut = rest.indexOf(stop);
      if (-1 != cut && cut < end) {
        end = cut;
      }
    }
    String authority = rest.substring(0, end);
    int last = authority.lastIndexOf('@');
    if (0 < last) {
      scan.secrets.add(path + " is a URL carrying userinfo, which puts a "
          + "credential in the config file; use the proxy feature's "
          + "`fromEnv` option instead (8.6)");
    }
  }

  /**
   * The SHAPE kindof, which must agree with struct's own spellings. NOT the
   * same function as Feature.kindof, and they must not be unified: the
   * feature checker's spellings are the descriptor's, not struct's.
   */
  static String kindof(Object val) {
    if (null == val) {
      return "null";
    }
    if (val instanceof List) {
      return "list";
    }
    if (val instanceof Number) {
      double d = ((Number) val).doubleValue();
      return Math.floor(d) == d ? "integer" : "decimal";
    }
    if (val instanceof Map) {
      return "object";
    }
    if (val instanceof Boolean) {
      return "boolean";
    }
    if (val instanceof String) {
      return "string";
    }
    return val.getClass().getSimpleName().toLowerCase();
  }

  private static String json(Object val) {
    return Descriptor.canonicalSerialize(val);
  }

  static boolean ismap(Object val) {
    return val instanceof Map;
  }

  static Object getprop(Object val, String key) {
    return Descriptor.getprop(val, key);
  }
}
