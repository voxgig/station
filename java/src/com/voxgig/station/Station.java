// The station library core, solo mode (station design D1): fully
// functional in-process with no other component running. The proxy (D2)
// is a deferred amplifier - `require` therefore fails on the operation
// path (design 2.1/14), and `auto` degrades to solo with one warning
// event.
//
// A port of typescript/src/Station.ts + adapter.ts, which are canonical.
// Java is an inverted-binding target (design 3.1): the app constructs the
// SDK through its existing generated constructor and hands it
// station-built options - `new SolardemoSDK(st.options())` - so this
// library has no connect(SDK)/adopt(SDK) sugar. The generated station
// feature reads the handle from its feature options and delegates to
// featureBinding() during construction, exactly as the ts/js adapters
// delegate to their library's featureBinding. The typed transport wrap
// itself is installed by the generated adapter (the library cannot see a
// generated FetcherFn type); everything the wrap DOES lives here.
//
// design 6's declarative front door lives here too: station.json declares
// the instances, Factory holds the constructors, and sdk()/create() stand
// them up on demand.

package com.voxgig.station;

import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;
import java.util.regex.Pattern;

@SuppressWarnings({"unchecked"})
public class Station {

  /** The inner transport a station wrap delegates to. */
  @FunctionalInterface
  public interface Transport {
    Object send(String fullurl, Map<String, Object> fetchdef);
  }

  private static Station ambient = null;
  private static String ambientOpts = null;

  private static final AtomicLong CORR = new AtomicLong(0);

  // Station wraps installed on any client's transport slot, process-wide:
  // the java spelling of the ts `__station__` marker (a lambda cannot
  // carry a property). Weak, so dead clients do not pin their wraps.
  private static final Set<Object> MARKED =
      Collections.synchronizedSet(Collections.newSetFromMap(new WeakHashMap<>()));

  private static final class PluginEntry {
    final String name;
    final String api;
    final Map<String, Object> descriptor;
    final String rung;
    final Object client;
    final List<String> warnings;
    // The EFFECTIVE secret name, resolved once at registration and read
    // from here at the transport seam with NO FALLBACK (design 7.4).
    final String secretname;

    PluginEntry(String name, String api, Map<String, Object> descriptor,
        String rung, Object client, List<String> warnings, String secretname) {
      this.name = name;
      this.api = api;
      this.descriptor = descriptor;
      this.rung = rung;
      this.client = client;
      this.warnings = warnings;
      this.secretname = secretname;
    }
  }

  private final Map<String, Object> opts;
  private final Object raw;
  private final Map<String, Object> profile;
  private final SecretBroker broker;
  private final EventBuffer buffer;

  // Design 7.1: keyed by INSTANCE NAME, not api slug. Two clients of one
  // api is the NORMAL case now; two bindings of one instance is still
  // station_bound_twice.
  private final Map<String, PluginEntry> registry = new LinkedHashMap<>();
  // Design 6.1: sdk(name) caches; create() deliberately does not.
  private final Map<String, Object> clients = new LinkedHashMap<>();
  // An auto-assigned tag to the DECLARED instance it stands for (design
  // 5.3). Kept beside the registry rather than inside it, because the
  // mapping exists before construction and blockFor() needs it during
  // registration.
  private final Map<String, String> aliasOf = new LinkedHashMap<>();
  // Design 7.4: the shared per-api descriptor cache - see describe().
  private final Map<String, Descriptor.Normalized> descriptorCache =
      new LinkedHashMap<>();

  private final boolean requireProxy;
  /** Design 6.3: which side of the repo review boundary the config is on. */
  public final boolean repoScoped;
  private boolean closed = false;

  /**
   * Design 6.2's second path, and the front door the docs name. Delegates
   * to the same process-global table the free function fills; there is one
   * registry, not two.
   */
  public static void provide(String api, Factory factory) {
    Factory.provide(api, factory);
  }

  /**
   * Ambient instance (design 10.2): open() is the idempotent process-wide
   * singleton; a second open() with conflicting options is an error;
   * `new Station(opts)` stays isolated for tests and multi-tenant hosts.
   * open() is non-blocking - solo involves no network, and the deferred
   * proxy probe must never change that.
   */
  public static synchronized Station open() {
    return open(null);
  }

  public static synchronized Station open(Map<String, Object> opts) {
    String key = Descriptor.canonicalSerialize(
        null == opts ? new LinkedHashMap<>() : opts);
    if (null != ambient) {
      if (!key.equals(ambientOpts)) {
        throw new StationError("station_open_conflict",
            "Station.open() was already called with different options");
      }
      return ambient;
    }
    ambient = new Station(opts);
    ambientOpts = key;
    return ambient;
  }

  /**
   * The ambient instance, or null - never creates one. The generated
   * station feature binds through this when no explicit handle rides its
   * options (design 3.1: binding is never implicit; only open() creates
   * the ambient instance).
   */
  public static synchronized Station current() {
    return ambient;
  }

  /** Test seam: drop the ambient instance. */
  public static synchronized void reset() {
    ambient = null;
    ambientOpts = null;
  }

  /**
   * Resolve the station a feature activation binds to: an explicit handle
   * in the feature options (st.options() passes one), else the ambient
   * instance. No station open -> null: an activated feature with no
   * opened station is an inert no-op that emits nothing and fails
   * nothing (design 3.1).
   */
  public static Station from(Map<String, Object> fopts) {
    Object handle = null == fopts ? null : fopts.get("station");
    if (handle instanceof Station) {
      return (Station) handle;
    }
    return current();
  }

  public Station() {
    this(null);
  }

  public Station(Map<String, Object> opts) {
    this.opts = null == opts ? new LinkedHashMap<>() : opts;

    Object config = this.opts.containsKey("config")
        ? this.opts.get("config")
        : Profile.loadConfig(text(this.opts.get("folder")));

    // Design 6.3. READ THE EXPLICIT OPTION FIRST: inferring before reading
    // it is a real precedence bug, one that makes `repoScoped: false`
    // unsettable for any caller passing a config in code - which is every
    // test of the rule. Then an in-code config (the application wrote it,
    // so it is repo-scoped by construction), then where the file was found.
    Object explicit = this.opts.get("repoScoped");
    this.repoScoped = explicit instanceof Boolean
        ? (Boolean) explicit
        : (this.opts.containsKey("config")
            || !"user".equals(Profile.configScope(text(this.opts.get("folder")))));

    // Normalize, then validate (design 4.2). A malformed station.json fails
    // open() with EVERY error at once - an eighteen-instance config must
    // not die because the eighteenth has a typo'd package name.
    //
    // resolveProfile then reads the RAW config, NOT the normalized one. The
    // normalized form is an input to validation and to nothing else: block
    // defaults synthesized before the profile merge would let a one-key
    // overlay overwrite the base's `active: false` and silently re-enable a
    // barred integration (design 3.3, 4.2).
    if (null != config) {
      Shape.validateConfig(Shape.normalizeConfig(config));
    }

    // The raw config, kept for design 8.7's provenance: the resolved
    // profile has already collapsed the levels that provenance has to name.
    this.raw = config;
    this.profile = Profile.resolveProfile(config,
        Profile.selectProfile(text(this.opts.get("profile"))));
    this.broker = new SecretBroker(this.profile.get("providers"));
    this.buffer = new EventBuffer();

    Object proxy = this.opts.get("proxy");
    if (null == proxy) {
      proxy = "auto";
    }
    this.requireProxy = "require".equals(proxy);

    if ("auto".equals(proxy)) {
      // The probe is deferred with the proxy itself; absence degrades to
      // solo with a single warning event naming the cause (design 14).
      warn(null, null, "proxy absent (not found); running solo");
    }

    warnPackages();
  }

  // --- the ref grammar (design 6.1) ---

  // The ref grammar is the JOINT identity model's: a name is a package-ish
  // specifier, a tag is not (it MAY start with a digit because auto-tagging
  // assigns integer tags, and admits neither `@` nor `/`); both cap at
  // 1024; the split is on the FIRST `$`, so `a$b$c` is a good name with a
  // bad tag.
  private static final Pattern REF_NAME_RE =
      Pattern.compile("^[a-zA-Z@][a-zA-Z0-9.~_\\-/]*$");
  private static final Pattern REF_TAG_RE =
      Pattern.compile("^[a-zA-Z0-9.~_-]+$");
  private static final int REF_MAX = 1024;

  public static boolean checkInstanceName(Object name) {
    if (!(name instanceof String)) {
      return false;
    }
    String text = (String) name;
    if (text.isEmpty() || REF_MAX < text.length()) {
      return false;
    }
    return REF_NAME_RE.matcher(text).matches();
  }

  public static boolean checkInstanceTag(Object tag) {
    if (!(tag instanceof String)) {
      return false;
    }
    String text = (String) tag;
    // The empty tag is an ordinary tag: the single-instance case writes no
    // tag and never learns tags exist.
    if (text.isEmpty()) {
      return true;
    }
    if (REF_MAX < text.length()) {
      return false;
    }
    return REF_TAG_RE.matcher(text).matches();
  }

  /**
   * Validate a ref against the joint grammar and return its CANONICAL
   * spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
   * `stripe` are ONE registry key rather than two.
   */
  public static String checkref(String ref) {
    int cut = ref.indexOf('$');
    String name = -1 == cut ? ref : ref.substring(0, cut);
    String tag = -1 == cut ? "" : ref.substring(cut + 1);
    if (!checkInstanceName(name)) {
      throw new StationError("station_instance_api",
          "invalid instance name \"" + name + "\" in ref \"" + ref + "\": a name "
              + "starts with a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, "
              + "max 1024 (6.1)");
    }
    if (!checkInstanceTag(tag)) {
      throw new StationError("station_instance_api",
          "invalid instance tag \"" + tag + "\" in ref \"" + ref + "\": a tag "
              + "uses `[a-zA-Z0-9.~_-]`, max 1024 (6.1)");
    }
    return tag.isEmpty() ? name : ref;
  }

  static String checkapi(String api, String ref) {
    if (!Profile.refapi(ref).equals(api)) {
      throw new StationError("station_instance_api",
          "instance \"" + ref + "\" names api \"" + Profile.refapi(ref)
              + "\", but the SDK passed is api \"" + api
              + "\"; `as` is a tag, not a free name (6.1)");
    }
    return ref;
  }

  /**
   * Design 6.1: `as` IS A TAG, NOT A FREE NAME.
   *
   * <p>The api comes from the SDK being built, so the resulting ref is
   * `api$tag` and multi-instance works imperatively too. A full ref is also
   * accepted and is VALIDATED: its name must equal the api slug, or it is
   * station_instance_api. An `as` that took an arbitrary name would
   * reintroduce the second-identity problem the ref re-key removed.
   *
   * <p>A bare call with no name falls back to the SLUG, a NAME and never a
   * ref: a `$` in it is an invalid name, not an implicit tag - which is
   * today's behaviour and why the single-instance case is unchanged.
   *
   * <p>A `$`-LESS STRING IS ALWAYS A TAG. `as: "stripe"` on api `stripe`
   * yields `stripe$stripe`, not `stripe`: design 6.1 says twice and
   * emphatically that `as` is a tag rather than a free name, and a rule
   * with no exceptions is the one that ports the same way twenty times.
   * Someone who wants the untagged instance passes no `as` at all.
   */
  public static String instanceRef(String api, Map<String, Object> fopts) {
    String explicit = firstNonEmpty(text(null == fopts ? null : fopts.get("instance")));
    if (null != explicit) {
      return checkref(checkapi(api, explicit));
    }

    String as = firstNonEmpty(text(null == fopts ? null : fopts.get("as")));
    if (null == as) {
      if (!checkInstanceName(api)) {
        throw new StationError("station_instance_api",
            "invalid instance name \"" + api + "\": a name starts with a letter "
                + "or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)");
      }
      return api;
    }

    return checkref(-1 == as.indexOf('$') ? api + "$" + as : checkapi(api, as));
  }

  // --- inverted binding (design 3.1) ---

  /**
   * Build the plain options map a generated constructor already accepts:
   * the caller's options plus the station activation entry carrying this
   * handle. The generated station feature performs registration and
   * credential placement during construction; the profile's per-instance
   * base is applied at binding time, when the instance is known.
   *
   * <p>Design 6.1: the instance name is OPTIONAL AND LEADING, so every
   * existing options({...}) call is unchanged - the inverted binding is the
   * static languages' path and they need to say which instance they are
   * building without a second method.
   */
  public Map<String, Object> options() {
    return options((Map<String, Object>) null);
  }

  public Map<String, Object> options(Map<String, Object> extra) {
    return options(null, extra);
  }

  public Map<String, Object> options(String instance, Map<String, Object> extra) {
    Map<String, Object> calleropts = null == extra ? new LinkedHashMap<>() : extra;
    Map<String, Object> out = new LinkedHashMap<>(calleropts);

    Map<String, Object> fmap = new LinkedHashMap<>(
        Descriptor.asmap(out.get("feature")));
    Map<String, Object> entry = new LinkedHashMap<>(
        Descriptor.asmap(fmap.get("station")));
    entry.put("active", true);
    entry.put("station", this);
    entry.put("calleropts", calleropts);
    if (null != instance && !instance.isEmpty()) {
      entry.put("instance", instance);
    }
    fmap.put("station", entry);
    out.put("feature", fmap);

    return out;
  }

  // --- the binding seam (design 3, called by the generated adapter) ---

  /**
   * The station side of the plugin contract (design 3), in ONE place - the
   * java spelling of the ts library's featureBinding(). The generated
   * StationFeature calls it from init() with the pieces the library cannot
   * reach through generated types: the client handle, the feature names in
   * add order, the current transport slot value, the embedded config, the
   * resolved options, and its own feature options.
   *
   * <p>Registration at init, wrap position verified, credential placeholder
   * planted (a resident credential is hoisted), returns the binding - or
   * null when this client is already bound (same construction, second
   * arrival must no-op; a genuinely second binding of one INSTANCE still
   * fails, design 10.2).
   */
  public synchronized Map<String, Object> featureBinding(Object client,
      List<String> featureNames, Object currentTransport,
      Map<String, Object> config, Map<String, Object> options,
      Map<String, Object> fopts) {

    if (null != boundEntry(client)) {
      return null;
    }

    // Position guard (design 3.3): the wrap must sit immediately outside
    // the base transport - inside retry/cache/ratelimit - or its http
    // events stop being wire truth. Position in client.features IS init
    // order, so verify it and fail loudly.
    int self = featureNames.indexOf("station");
    int testAt = featureNames.indexOf("test");
    int expected = 0 > testAt ? 0 : testAt + 1;
    if (self != expected) {
      throw new StationError("station_wrap_order",
          "station must init immediately after the base transport; "
              + "feature order is [" + String.join(", ", featureNames) + "]");
    }

    Descriptor.Normalized normalized = describe(config);
    Map<String, Object> descriptor = normalized.descriptor;
    String api = (String) descriptor.get("slug");

    // Design 7.5: station knows the instance name before construction
    // begins and passes it through the feature options. A bare binding with
    // no name falls back to the descriptor slug.
    String name = instanceRef(api, fopts);

    if (registry.containsKey(name)) {
      throw new StationError("station_bound_twice",
          "instance \"" + name + "\" is already registered; binding one client "
              + "twice is an error (design 10.2)");
    }

    Map<String, Object> block = blockFor(name);

    // Secret name precedence: the feature option (in-code, design 9
    // config.options.secret) beats the profile block, which beats the
    // INSTANCE-derived default.
    //
    // Design 5.1: secretnameDefault takes the DECLARED ref, not the
    // assigned tag, so every per-request client of one instance shares one
    // broker cache entry. For an untagged instance the ref and the slug are
    // the same string, so the single-instance case is unchanged to the
    // byte.
    //
    // The descriptor's own `auth.secretname` stays the API-level default
    // and is NOT used here (design 7.4): one descriptor is shared by every
    // instance of an api and cannot hold two instance-derived names.
    String foptSecret = text(null == fopts ? null : fopts.get("secret"));
    String secretname = firstNonEmpty(foptSecret, text(block.get("secret")));
    if (null == secretname) {
      secretname = Descriptor.secretnameDefault(declaredRef(name));
    }

    Map<String, Object> auth = Descriptor.asmap(descriptor.get("auth"));
    boolean authActive = Boolean.TRUE.equals(auth.get("active"));
    String rung = authActive ? "R1" : "none";

    Map<String, Object> binding = new LinkedHashMap<>();
    binding.put("plugin", name);
    binding.put("api", api);
    if (authActive) {
      // Design 7.2: two live instances of one api MUST have distinct
      // placeholders or the injection seam cannot tell which credential a
      // header wants.
      binding.put("placeholder", SecretBroker.placeholderFor(name));
      binding.put("secretname", secretname);
    }
    binding.put("rung", rung);

    registry.put(name, new PluginEntry(name, api, descriptor, rung, client,
        normalized.warnings, authActive ? secretname : null));

    for (String warning : normalized.warnings) {
      warn(name, api, warning);
    }
    Map<String, Object> meta = new LinkedHashMap<>();
    meta.put("name", descriptor.get("name"));
    meta.put("version", descriptor.get("version"));
    meta.put("rung", rung);
    Map<String, Object> event = event("construct", name, api, null);
    event.put("meta", meta);
    emit(event);

    // Base URL precedence (design 3.5): caller opts (7) beat the profile
    // (4), which beats the SDK's config default (1) already in
    // options.base. calleropts is what st.options() was handed, so an
    // explicit caller base wins.
    Object calleropts = null == fopts ? null : fopts.get("calleropts");
    if (calleropts instanceof Map && null != options
        && null == ((Map<String, Object>) calleropts).get("base")
        && null != block.get("base")) {
      options.put("base", block.get("base"));
    }

    // Policy allowlists (design 16): `allow.op` / `allow.method` are the
    // same vocabulary the SDKs already enforce - `options.allow`, and the
    // raw-access gate every target implements - so station sets those SDK
    // options FROM policy and enforcement stays in the SDK's own pipeline.
    // The SDK's own option form is a comma-separated string, so the
    // policy's list joins into it.
    //
    // Unlike `base` above, which is a DEFAULT the caller may override, an
    // allowlist is ENFORCEMENT: policy wins over whatever the options
    // carry, on exactly the keys it sets.
    Object policyAllow = Descriptor.getprop(block.get("policy"), "allow");
    if (policyAllow instanceof Map && null != options) {
      Map<String, Object> allow = new LinkedHashMap<>(
          Descriptor.asmap(options.get("allow")));
      Object ops = Descriptor.getprop(policyAllow, "op");
      if (ops instanceof List) {
        allow.put("op", joinlist((List<Object>) ops));
      }
      Object methods = Descriptor.getprop(policyAllow, "method");
      if (methods instanceof List) {
        allow.put("method", joinlist((List<Object>) methods));
      }
      options.put("allow", allow);
    }

    if (!"none".equals(rung) && null != options) {
      String placeholder = SecretBroker.placeholderFor(name);

      // A real credential already resident in the options is hoisted into
      // the broker and replaced by the placeholder before construction
      // completes (design 3.1 adopt) - options() and prepare() output
      // become placeholder-safe from here on.
      Object resident = options.get("apikey");
      if (resident instanceof String && !((String) resident).isEmpty()
          && !placeholder.equals(resident)) {
        broker.hoist(name, (String) resident);
        warn(name, api, "a resident credential was hoisted into the broker and "
            + "replaced by the placeholder; prefer configuring the secret "
            + "name and letting sekreto resolve it");
      }
      options.put("apikey", placeholder);
    }

    // Double-wrap guard: a station wrap already on the transport slot means
    // another Station instance bound this client (the same instance no-ops
    // above).
    if (isStationTransport(currentTransport)) {
      throw new StationError("station_bound_twice",
          "instance \"" + name + "\" already carries a station wrap");
    }

    return binding;
  }

  private static String joinlist(List<Object> values) {
    List<String> out = new ArrayList<>();
    for (Object value : values) {
      out.add(String.valueOf(value));
    }
    return String.join(",", out);
  }

  /** Record a transport wrap so the double-wrap guard can spot it. */
  public void markTransport(Object wrap) {
    if (null != wrap) {
      MARKED.add(wrap);
    }
  }

  /** Is this transport slot value a station wrap (any instance's)? */
  public boolean isStationTransport(Object transport) {
    return null != transport && MARKED.contains(transport);
  }

  /** A fresh per-operation correlation id (design 3 item 3). */
  public String nextCorr() {
    return "c" + CORR.incrementAndGet();
  }

  private PluginEntry boundEntry(Object client) {
    for (PluginEntry entry : registry.values()) {
      if (entry.client == client) {
        return entry;
      }
    }
    return null;
  }

  /**
   * The profile block that governs an instance - its own if the profile
   * declares it, otherwise its API'S.
   *
   * <p>resolveProfile builds profile.sdk from the DECLARED refs alone, which
   * leaves an IMPERATIVE instance - named at construction but never written
   * into config - with no block at all, so the api-level `secret`, `base`
   * and most seriously `policy.hosts` did not reach it, and a profile that
   * denied egress everywhere denied nothing for a tagged client.
   *
   * <p>ONE RULE, ONE PLACE: registration and the transport seam both ask
   * here, because their disagreeing is how the credential and the allowlist
   * came apart in the first place.
   */
  public Map<String, Object> blockFor(String name) {
    Object own = Descriptor.getprop(profile.get("sdk"), declaredRef(name));
    if (own instanceof Map) {
      return (Map<String, Object>) own;
    }
    return Descriptor.asmap(
        Descriptor.getprop(profile.get("api"), Profile.refapi(name)));
  }

  /**
   * The DECLARED instance an assigned tag stands for, or the name itself.
   * create("stripe$prod") registers under `stripe$1`, and every question
   * about that client's configuration - its secret, its base, its egress
   * policy - is a question about `stripe$prod`.
   */
  public synchronized String declaredRef(String name) {
    String declared = aliasOf.get(name);
    return null == declared ? name : declared;
  }

  /**
   * Design 7.4: THE DESCRIPTOR IS SHARED, because it describes the API
   * rather than any use of it. normalizeDescriptor runs once per api and
   * every instance of that api holds a reference to the same object - at 26
   * instances over 20 apis that is 20 normalizations, not 26, and the
   * canonical serialization is computed once per api too.
   *
   * <p>Normalized with NO per-instance features, so the shared value holds
   * only api-stable metadata - which is what Factory already does at
   * provide time. Per-instance activation is featuresOf(name)'s answer; a
   * cache keyed by slug but built from the first instance's feature map
   * would make descriptorOf() construction-order-dependent.
   */
  private synchronized Descriptor.Normalized describe(Object config) {
    String slug = String.valueOf(
        Descriptor.textor(Descriptor.getprop(
            Descriptor.getprop(config, "main"), "slug"), ""));
    if (!slug.isEmpty()) {
      Descriptor.Normalized hit = descriptorCache.get(slug);
      if (null != hit) {
        return hit;
      }
    }
    Descriptor.Normalized out = Descriptor.normalizeDescriptor(config, null);
    descriptorCache.put((String) out.descriptor.get("slug"), out);
    return out;
  }

  // --- the transport middleware (design 3.3, 5.3) ---

  /**
   * The station middleware body, called by the generated wrap on every
   * request: policy, injection with copy-on-inject, and the http event.
   * `live` is whether the base transport is the real one (mock modes ride
   * through untouched, so real credentials never enter in-memory mock
   * stores, design 3.3); `corr` is the per-operation id the hook bridge
   * planted, null on the direct()/graphql() path.
   *
   * <p>`name` is the INSTANCE name (design 7.1), which for an untagged
   * instance is the api slug.
   */
  public Object transport(String name, String fullurl,
      Map<String, Object> fetchdef, boolean live, String corr,
      Transport inner) {

    // Fail-closed means traffic (design 2.1): with the proxy deferred,
    // `require` can never attach, so every operation fails here - the
    // operation path, never the constructor.
    if (requireProxy) {
      StationError err = new StationError("station_no_proxy",
          "proxy: \"require\" is set and no proxy is attached");
      emitErr(name, corr, err);
      throw err;
    }

    PluginEntry entry;
    synchronized (this) {
      entry = registry.get(name);
    }
    String placeholder = SecretBroker.placeholderFor(name);
    Map<String, Object> block = blockFor(name);

    // Egress policy (design 16), solo half: the hosts allowlist is enforced
    // at the seam every request crosses. When a policy is present,
    // redirects come back manual - a 3xx is a response like any other, so a
    // Location off the allowlist cannot pull an automatic credentialed
    // follow-up to an unapproved host (design 8.2's rule, applied at the
    // library seam).
    Object hosts = Descriptor.getprop(block.get("policy"), "hosts");
    if (hosts instanceof List && live) {
      String hostname = "";
      try {
        String h = URI.create(fullurl).getHost();
        hostname = null == h ? "" : h;
      } catch (RuntimeException ignored) {
        // Unparseable url: hostname stays '', which no allowlist holds.
      }
      if (!((List<Object>) hosts).contains(hostname)) {
        StationError err = new StationError("station_host_allow",
            "egress to \"" + hostname + "\" denied by the hosts policy of "
                + "plugin \"" + name + "\"");
        emitErr(name, corr, err);
        throw err;
      }
    }

    Map<String, Object> senddef = fetchdef;
    if (hosts instanceof List && live) {
      senddef = new LinkedHashMap<>(senddef);
      senddef.put("redirect", "manual");
    }

    // Injection: at the last boundary, below every recording feature, and
    // never into mock transports (design 3.3). Copy-on-inject: the object
    // graph reachable from ctx/spec/ctrl keeps the placeholder, ever
    // (design 5.3).
    if (live && null != entry && "R1".equals(entry.rung)) {
      // Design 7.4: THE EFFECTIVE NAME, resolved once at registration and
      // stored on the entry, read here with NO FALLBACK. Re-deriving it
      // here got the precedence right and the FALLBACK wrong:
      // descriptor.auth.secretname is the API-level default, and one
      // descriptor is shared by every instance of an api - so a tagged
      // instance with no explicit `secret` read `stripe.apikey` where
      // registration had recorded `stripe_test.apikey`.
      String secretname = entry.secretname;

      String value;
      try {
        value = broker.value(name, secretname);
      } catch (StationError err) {
        emitErr(name, corr, err);
        throw err;
      }

      senddef = new LinkedHashMap<>(senddef);
      Map<String, Object> headers = new LinkedHashMap<>(
          Descriptor.asmap(senddef.get("headers")));
      for (Map.Entry<String, Object> header : headers.entrySet()) {
        Object v = header.getValue();
        if (v instanceof String && ((String) v).contains(placeholder)) {
          header.setValue(((String) v).replace(placeholder, value));
        }
      }
      senddef.put("headers", headers);
    }

    long started = System.currentTimeMillis();

    Object res;
    try {
      res = inner.send(fullurl, senddef);
    } catch (RuntimeException err) {
      emitHttp(name, corr, fullurl, senddef, 0, started, 0);
      emitErr(name, corr, err);
      throw err;
    }

    int status = 0;
    long bytes = 0;
    if (res instanceof Map) {
      Object s = ((Map<String, Object>) res).get("status");
      if (s instanceof Number) {
        status = ((Number) s).intValue();
      }
      Object cl = Descriptor.getprop(
          ((Map<String, Object>) res).get("headers"), "content-length");
      if (null != cl) {
        try {
          bytes = Long.parseLong(String.valueOf(cl).trim());
        } catch (NumberFormatException ignored) {
          bytes = 0;
        }
      }
    }
    emitHttp(name, corr, fullurl, senddef, status, started, bytes);

    return res;
  }

  /** Op events from the hook bridge (design 3 item 3). */
  public void opEvent(String name, String corr, Long start,
      String entity, String opname, String outcome) {
    Map<String, Object> op = new LinkedHashMap<>();
    op.put("entity", null == entity ? "" : entity);
    op.put("op", null == opname ? "" : opname);
    op.put("outcome", outcome);
    op.put("durationMs", null == start ? 0L
        : System.currentTimeMillis() - start);

    Map<String, Object> event = event("op", name, Profile.refapi(name), corr);
    event.put("op", op);
    emit(event);
  }

  private void emitHttp(String name, String corr, String fullurl,
      Map<String, Object> fetchdef, int status, long started, long bytes) {
    String host = "";
    String path = "";
    try {
      URI u = URI.create(fullurl);
      String h = u.getHost();
      host = null == h ? "" : (0 <= u.getPort() ? h + ":" + u.getPort() : h);
      path = null == u.getPath() ? "" : u.getPath();
    } catch (RuntimeException ignored) {
      path = fullurl;
    }

    Map<String, Object> http = new LinkedHashMap<>();
    Object method = null == fetchdef ? null : fetchdef.get("method");
    http.put("method", method instanceof String && !"".equals(method)
        ? method : "GET");
    http.put("host", host);
    http.put("path", path);
    http.put("status", status);
    http.put("durationMs", System.currentTimeMillis() - started);
    http.put("bytes", bytes);

    Map<String, Object> event = new LinkedHashMap<>();
    event.put("t", started);
    event.put("kind", "http");
    event.put("plugin", name);
    event.put("api", Profile.refapi(name));
    if (null != corr) {
      event.put("corr", corr);
    }
    event.put("http", http);
    emit(event);
  }

  private void emitErr(String name, String corr, RuntimeException err) {
    Map<String, Object> errmap = new LinkedHashMap<>();
    if (err instanceof StationError) {
      errmap.put("code", ((StationError) err).code);
    }
    // The scrub keeps an upstream echo of a credential out of the event
    // stream (design 7 as revised: exact-value, no length floor).
    String message = null == err.getMessage()
        ? String.valueOf(err) : err.getMessage();
    errmap.put("message", redact(message));

    Map<String, Object> event = event("error", name, Profile.refapi(name), corr);
    event.put("err", errmap);
    emit(event);
  }

  // --- the declarative front door (design 6) ---

  /**
   * The instance, constructed on first call and CACHED: same name -> same
   * object. That caching is what makes "get it where you need it" a real
   * instruction - call it in a request handler, in a worker, in a test, and
   * the first call pays construction while the rest are a map lookup.
   * SYNCHRONOUS.
   */
  public Object sdk(String name) {
    synchronized (this) {
      Object cached = clients.get(name);
      if (null != cached) {
        return cached;
      }
    }
    Object client = build(name, null, null);
    synchronized (this) {
      clients.put(name, client);
    }
    return client;
  }

  /**
   * An UNCACHED client from the same resolved config plus overrides, for
   * the case that genuinely wants a distinct one - a per-request credential
   * scope, a test double. Deliberately the longer name.
   *
   * <p>It registers under an AUTO-ASSIGNED TAG, because every constructed
   * adapter registers under its instance name and station_bound_twice fires
   * on a second binding of one name: a second create("stripe") would
   * otherwise throw, which is exactly the per-request case this exists for.
   */
  public Object create(String name) {
    return create(name, null);
  }

  public Object create(String name, Map<String, Object> overrides) {
    return build(name, autotag(name), overrides);
  }

  /**
   * The lowest positive integer tag not already taken, by a LIVE instance
   * or a DECLARED one.
   *
   * <p>THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`,
   * and until something constructs it the registry says false - so
   * create("stripe$prod") would take that identity, instances() would
   * report the declared `stripe$1` as live with the wrong client, and a
   * later sdk("stripe$1") would fail station_bound_twice against a binding
   * that was never its own. Declaration reserves the name whether or not it
   * has been built.
   */
  public synchronized String autotag(String name) {
    String api = Profile.refapi(name);
    Map<String, Object> sdk = Descriptor.asmap(profile.get("sdk"));
    for (int n = 1; ; n++) {
      String ref = api + "$" + n;
      if (!registry.containsKey(ref) && null == sdk.get(ref)) {
        return ref;
      }
    }
  }

  /** The shared construction path behind sdk() and create(). */
  public Object build(String name, String as, Map<String, Object> overrides) {
    Map<String, Object> sdk;
    synchronized (this) {
      if (closed) {
        throw new StationError("station_no_plugin", "station is closed");
      }
      sdk = Descriptor.asmap(profile.get("sdk"));
    }

    Object raw = sdk.get(name);
    if (null == raw) {
      throw new StationError("station_no_instance",
          "no declared instance \"" + name + "\"; declared: ["
              + String.join(", ", new TreeSet<>(sdk.keySet())) + "]");
    }
    Map<String, Object> block = Descriptor.asmap(raw);
    if (Boolean.FALSE.equals(block.get("active"))) {
      throw new StationError("station_instance_inactive",
          "instance \"" + name + "\" is declared with `active: false`, which "
              + "bars it from running while keeping it visible in instances()");
    }

    String api = Profile.refapi(name);
    Factory.Entry entry = resolveFactory(api, block);

    Map<String, Object> resolved = featuresOf(name);
    Map<String, Object> merged = Descriptor.asmap(resolved.get("merged"));

    // Design 8.5 VALIDATES HERE, not only in check(). The schema arrives
    // with the factory, so the moment a factory is resolved is the first
    // moment validation is possible - and running it in check() alone left
    // two gaps: production sdk() silently ignored an unknown option like
    // `retry.retires`, and check() itself missed the case where the factory
    // is discovered by the loader. One call here closes both, because EVERY
    // path to a constructor comes through this line.
    List<Feature.Fault> faults = Feature.checkfeatures(merged, entry.descriptor);
    if (!faults.isEmpty()) {
      throw new StationError(faults.get(0).code, Feature.faultMessages(faults));
    }

    // Design 8.4: compose the merged feature map into the ORDERED form and
    // hand it to the constructor. Station's own entry is composed AFTER the
    // user merge and always wins, which is why `station` is dropped here
    // and re-added by options(): a config file that can switch off the
    // component reading it is not a surface, it is a trap. `feature.station`
    // is already station_feature_reserved at validation, so this is the
    // second half of one rule rather than a second rule.
    //
    // A LinkedHashMap keeps the composed order, so it rides the options map
    // the same way a JavaScript object's insertion order does.
    List<Feature.Ordered> rows = new ArrayList<>();
    for (Feature.Ordered row : Feature.resolveorder(merged)) {
      if (!"station".equals(row.name)) {
        rows.add(row);
      }
    }
    Map<String, Object> fmap = new LinkedHashMap<>();
    for (Map<String, Object> one : Feature.composefeatures(rows)) {
      Map<String, Object> rest = new LinkedHashMap<>(one);
      Object fname = rest.remove("name");
      fmap.put(String.valueOf(fname), rest);
    }

    Map<String, Object> built = new LinkedHashMap<>();
    built.putAll(Descriptor.asmap(block.get("options")));
    if (null != block.get("base")) {
      built.put("base", block.get("base"));
    }
    if (null != overrides) {
      built.putAll(overrides);
    }
    fmap.putAll(Descriptor.asmap(
        Descriptor.getprop(overrides, "feature")));
    built.put("feature", fmap);

    // RECORD THE ALIAS, NOT THE FIELDS. Carrying the declared `secret`
    // through the feature options and stopping there leaves `policy`,
    // `base` and everything else behind, so an auto-tagged client silently
    // loses its declared instance's HOSTS ALLOWLIST and falls back to the
    // wider api-level one. Recording what the tag STANDS FOR is one rule
    // that every lookup already goes through.
    //
    // Only when the tag was ASSIGNED - a caller naming its own is naming an
    // instance, not aliasing one.
    String registerAs = name;
    if (null != as && !as.equals(name)) {
      synchronized (this) {
        aliasOf.put(as, name);
      }
      registerAs = as;
    }

    // The instance name reaches the adapter the same way it does on the
    // imperative path, so registration has one spelling (design 7.5). Java
    // has NO CARRIED ADAPTER - a library-carried adapter cannot implement a
    // generated SDK's Feature interface without depending on generated code
    // - so design 3.1's retrofit path here is regeneration with the station
    // feature installed, and the constructor's own feature is what binds.
    return entry.construct.construct(options(registerAs, built));
  }

  /**
   * Design 6.2's paths to a factory, in order of preference. THIS PORT HAS
   * TWO: self-registration through a ServiceLoader Registrar on the
   * classpath, and Station.provide. The third, the LOADER, does not exist
   * here and cannot - a Java `import` is a compile-time name alias that
   * loads nothing, and `package` names a module in some other language's
   * registry. So station_no_factory names ONLY the remedies this port
   * actually offers; a message telling a Java user to set
   * `api.slug.package` would send them down a road with no end (design
   * 5.4 item 3).
   */
  public Factory.Entry resolveFactory(String api, Map<String, Object> block) {
    Factory.Entry direct = Factory.factoryFor(api);
    if (null != direct) {
      return direct;
    }

    throw new StationError("station_no_factory",
        "no factory for api \"" + api + "\"; either put a generated package "
            + "on the classpath that self-registers through a "
            + "META-INF/services com.voxgig.station.Factory$Registrar entry, "
            + "or call Station.provide(\"" + api + "\", ...). `package` is not "
            + "honoured in the Java port: an `import` is a compile-time name "
            + "alias that loads nothing, so there is no import-by-name at run "
            + "time (6.3)");
  }

  /**
   * Always null here, and design 5.4 item 2 says why once per api at open.
   * `package` and `export` stay IN THE GRAMMAR - they are shape keys, the
   * corpus validates configs carrying them, and removing them would break
   * one-config-file-serves-a-polyglot-fleet - but this port cannot honour
   * them, and silence about that is worse than a warning.
   */
  public String loaderPackage(String api, Map<String, Object> block) {
    return null;
  }

  /**
   * Present and INERT (design 5.4 item 4): the preload exists so one
   * startup sequence serves a polyglot fleet. `load: false` is accepted and
   * equally inert.
   */
  public void load() {
    // Deliberately empty - see Loader.java.
  }

  // One warning event per api whose declared block carries a non-empty
  // `package`, at open, once.
  private void warnPackages() {
    Map<String, Object> blocks = new LinkedHashMap<>();
    blocks.putAll(Descriptor.asmap(profile.get("sdk")));
    for (Map.Entry<String, Object> e
        : Descriptor.asmap(profile.get("api")).entrySet()) {
      if (!blocks.containsKey(e.getKey())) {
        blocks.put(e.getKey(), e.getValue());
      }
    }

    Set<String> seen = new LinkedHashSet<>();
    for (String ref : new TreeSet<>(blocks.keySet())) {
      String pkg = text(Descriptor.getprop(blocks.get(ref), "package"));
      if (null == pkg || pkg.isEmpty()) {
        continue;
      }
      String api = Profile.refapi(ref);
      if (!seen.add(api)) {
        continue;
      }
      warn(api, api, "`package` is not honoured in the Java port: an `import` "
          + "is a compile-time name alias that loads nothing, so there is no "
          + "import-by-name at run time. api \"" + api + "\" must arrive by "
          + "self-registration (a META-INF/services "
          + "com.voxgig.station.Factory$Registrar entry) or Station.provide "
          + "(6.3); everything else in this config still applies");
    }
  }

  /**
   * The merged, ordered feature set for one instance, WITH PROVENANCE
   * (design 8.7): which config level set each value. Returns
   * {ordered, merged, from}.
   *
   * <p>Provenance is the half that makes a fleet view usable rather than
   * merely correct - at 26 instances "why is retry off here" is the
   * question, and a merged map alone cannot answer it.
   */
  public Map<String, Object> featuresOf(String name) {
    String api = Profile.refapi(name);
    Map<String, Object> profiles = Descriptor.asmap(
        Descriptor.getprop(raw, "profiles"));
    String profileName = String.valueOf(profile.get("name"));

    Object base = profiles.get("default");
    Object overlay = "default".equals(profileName)
        ? new LinkedHashMap<String, Object>() : profiles.get(profileName);

    // LEVELS: one label per source, in design 3.3's order.
    List<String> levels = List.of(
        "default.feature", "default.api", "default.sdk",
        profileName + ".feature", profileName + ".api", profileName + ".sdk");
    List<Object> sources = Feature.featuresources(base, overlay, api, name);

    // Last writer per (feature, key) wins, and the level that wrote it is
    // what `from` records.
    Map<String, Object> from = new LinkedHashMap<>();
    for (int index = 0; index < sources.size(); index++) {
      if (!(sources.get(index) instanceof Map)) {
        continue;
      }
      for (Map.Entry<String, Object> fe
          : ((Map<String, Object>) sources.get(index)).entrySet()) {
        if (!(fe.getValue() instanceof Map)) {
          continue;
        }
        Map<String, Object> one = (Map<String, Object>) from
            .computeIfAbsent(fe.getKey(), k -> new LinkedHashMap<String, Object>());
        for (String key : ((Map<String, Object>) fe.getValue()).keySet()) {
          one.put(key, levels.get(index));
        }
      }
    }

    Map<String, Object> merged = Feature.mergefeatures(sources);

    // Policy budget (design 16): rps/concurrency ceilings ride "the SDK
    // `ratelimit` feature, configured by station". Composed HERE, into the
    // merged map every consumer reads, rather than patched in at
    // construction alone - so build() orders it with the ordinary
    // constraint-and-band rules, check()'s design 8.5 pass validates it
    // against the SDK's own declaration (a budget on an SDK with no
    // ratelimit feature is station_feature_unknown, not a setting that
    // quietly did nothing), and the fleet view answers "is ratelimit on?"
    // truthfully.
    //
    // `rps` maps to the token bucket's refill `rate` (per second - the same
    // unit); `concurrency` to its capacity `burst`, the number of requests
    // that can be in flight from a full bucket. POLICY WINS over a
    // feature.ratelimit config entry on exactly the keys it sets - it is
    // enforcement, not a default - and other tuning keys survive beside it.
    Object budget = Descriptor.getprop(
        blockFor(name).get("policy"), "budget");
    if (budget instanceof Map) {
      Map<String, Object> entry = new LinkedHashMap<>(
          Descriptor.asmap(merged.get("ratelimit")));
      entry.put("active", Boolean.TRUE);
      Map<String, Object> ratefrom = (Map<String, Object>) from
          .computeIfAbsent("ratelimit", k -> new LinkedHashMap<String, Object>());
      ratefrom.put("active", "policy.budget");
      Object rps = Descriptor.getprop(budget, "rps");
      if (null != rps) {
        entry.put("rate", rps);
        ratefrom.put("rate", "policy.budget");
      }
      Object concurrency = Descriptor.getprop(budget, "concurrency");
      if (null != concurrency) {
        entry.put("burst", concurrency);
        ratefrom.put("burst", "policy.budget");
      }
      merged.put("ratelimit", entry);
    }

    // THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station` is
    // never in `merged` - feature.station is reserved and rejected at
    // validation (design 8.4) - so without it checkpin finds no station row
    // and is a PERMANENT NO-OP: a constraint like
    // `retry.order.after: "station"` would be treated as vacuous rather
    // than rejected, and the reported order would omit the one feature
    // whose position is supposedly pinned. `merged` itself stays the user's
    // own merge result.
    Map<String, Object> withStation = new LinkedHashMap<>(merged);
    Map<String, Object> stationEntry = new LinkedHashMap<>();
    stationEntry.put("active", Boolean.TRUE);
    withStation.put("station", stationEntry);

    List<Feature.Ordered> ordered = Feature.resolveorder(withStation);
    Feature.checkpin(ordered);

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("ordered", Feature.featureNames(ordered));
    out.put("merged", merged);
    out.put("from", from);
    return out;
  }

  /** The fleet feature view's filter (design 8.7). */
  public static final class FeatureFilter {
    public String instance;
    public String api;
    public String feature;
    boolean loose = false;
  }

  /**
   * The string shorthand: "this instance or this api", loose. Only the
   * object form can express the question the view exists for -
   * {feature: "debug"}, "is debug on anywhere?", the one that is twenty
   * greps today.
   */
  public static FeatureFilter looseFilter(String text) {
    FeatureFilter out = new FeatureFilter();
    out.instance = text;
    out.api = text;
    out.loose = true;
    return out;
  }

  public List<Map<String, Object>> features() {
    return features(null);
  }

  /**
   * The fleet feature view: instance x feature, effective options, and
   * which config level set each (design 8.7).
   */
  public List<Map<String, Object>> features(FeatureFilter filter) {
    FeatureFilter f = null == filter ? new FeatureFilter() : filter;

    List<Map<String, Object>> rows = new ArrayList<>();
    for (Map<String, Object> one : instances()) {
      String rowname = String.valueOf(one.get("name"));
      String rowapi = String.valueOf(one.get("api"));

      if (f.loose) {
        if (null != f.instance && !rowname.equals(f.instance)
            && !rowapi.equals(f.api)) {
          continue;
        }
      } else {
        if (null != f.instance && !rowname.equals(f.instance)
            && !rowapi.equals(f.instance)) {
          continue;
        }
        if (null != f.api && !rowapi.equals(f.api)) {
          continue;
        }
      }

      Map<String, Object> row = new LinkedHashMap<>();
      row.put("instance", rowname);
      row.put("api", rowapi);
      row.putAll(featuresOf(rowname));
      rows.add(row);
    }

    // `feature` filters the ROWS, not the instances: an instance that does
    // not carry the named feature is not part of the answer, and the rows
    // that remain are narrowed to it, so the view answers "where is debug
    // on, and with what" rather than "here is everything, go and look".
    if (null == f.feature) {
      return rows;
    }
    List<Map<String, Object>> narrowed = new ArrayList<>();
    for (Map<String, Object> row : rows) {
      Map<String, Object> merged = Descriptor.asmap(row.get("merged"));
      if (!merged.containsKey(f.feature)) {
        continue;
      }
      List<String> ordered = new ArrayList<>();
      for (Object n : (List<Object>) row.get("ordered")) {
        if (f.feature.equals(n)) {
          ordered.add(String.valueOf(n));
        }
      }
      Map<String, Object> onemerged = new LinkedHashMap<>();
      onemerged.put(f.feature, merged.get(f.feature));
      Map<String, Object> onefrom = new LinkedHashMap<>();
      onefrom.put(f.feature, Descriptor.asmap(
          Descriptor.getprop(row.get("from"), f.feature)));

      Map<String, Object> out = new LinkedHashMap<>();
      out.put("instance", row.get("instance"));
      out.put("api", row.get("api"));
      out.put("ordered", ordered);
      out.put("merged", onemerged);
      out.put("from", onefrom);
      narrowed.add(out);
    }
    return narrowed;
  }

  /**
   * Eagerly resolve and construct every ACTIVE declared instance - for CI
   * (design 6.6). The point is to turn availability errors, which are
   * deliberately deferred to first use, into ONE failure at a moment
   * somebody is watching. Returns {ok, failed}.
   */
  public Map<String, Object> check() {
    List<String> ok = new ArrayList<>();
    List<Map<String, Object>> failed = new ArrayList<>();

    for (Map<String, Object> row : instances()) {
      if (!Boolean.TRUE.equals(row.get("active"))) {
        continue;
      }
      String name = String.valueOf(row.get("name"));
      try {
        // Design 8.5 runs FIRST and needs no construction: the schema
        // arrives with the factory, not with a live client, so a feature
        // typo is a CI failure rather than a setting that quietly did
        // nothing in production.
        Factory.Entry entry = Factory.factoryFor(row.get("api"));
        if (null != entry) {
          List<Feature.Fault> faults = Feature.checkfeatures(
              Descriptor.asmap(featuresOf(name).get("merged")), entry.descriptor);
          if (!faults.isEmpty()) {
            failed.add(failure(name, faults.get(0).code,
                Feature.faultMessages(faults)));
            continue;
          }
        }
        sdk(name);
        ok.add(name);
      } catch (StationError err) {
        failed.add(failure(name, err.code, err.getMessage()));
      } catch (RuntimeException err) {
        failed.add(failure(name, null, String.valueOf(err.getMessage())));
      }
    }

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("ok", ok);
    out.put("failed", failed);
    return out;
  }

  private static Map<String, Object> failure(String name, String code,
      String message) {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("name", name);
    out.put("code", code);
    out.put("message", message);
    return out;
  }

  public Map<String, Object> warm() {
    return warm(null);
  }

  /**
   * Batch-resolve secrets (design 5.5). Returns {warmed, missed}, both
   * SORTED.
   *
   * <p>With no argument it warms the ACTIVE declared instances only, because
   * reaching for a credential belonging to a disabled integration is the
   * wrong default. warm(names) warms exactly what it is given, inactive
   * included, because an explicit name is an explicit request.
   *
   * <p>THE REGISTRY IS THE AUTHORITY: a registered instance already carries
   * the resolved name, in-code `secret` feature option included. A NAME
   * NOBODY DECLARED OR REGISTERED IS A MISS, not a lookup - a wider
   * fallback would let a typo like `stripe$prodd` derive a secret name, call
   * the provider, and report a nonexistent instance `warmed` off a shared
   * api-level credential. Registered OR declared, and nothing else.
   *
   * <p>The plan is GROUPED BY SECRET NAME and resolved once per distinct
   * name: the broker's resolution cache is keyed by secret name (design
   * 5.3), so several instances sharing one api-level `secret` cost one
   * round-trip. This port then resolves the deduplicated set SERIALLY -
   * every public station operation is safe from any thread (design 10.2),
   * so the broker is a monitor and the sekreto chain under it documents no
   * thread safety; firing the names concurrently would serialize on that
   * monitor anyway. The deduplication is what warm() actually saves here.
   */
  public Map<String, Object> warm(List<String> names) {
    List<String> wanted = new ArrayList<>();
    if (null != names) {
      wanted.addAll(names);
    } else {
      for (Map<String, Object> row : instances()) {
        if (Boolean.TRUE.equals(row.get("active"))) {
          wanted.add(String.valueOf(row.get("name")));
        }
      }
    }

    List<String> warmed = new ArrayList<>();
    List<String> missed = new ArrayList<>();

    Map<String, List<String>> bysecret = new LinkedHashMap<>();
    for (String name : wanted) {
      PluginEntry entry;
      boolean declared;
      synchronized (this) {
        entry = registry.get(name);
        declared = null != Descriptor.asmap(profile.get("sdk")).get(name);
      }
      if (null == entry && !declared) {
        missed.add(name);
        continue;
      }

      String secretname = null == entry ? null : entry.secretname;
      if (null == secretname) {
        secretname = text(blockFor(name).get("secret"));
      }
      if (null == secretname || secretname.isEmpty()) {
        secretname = Descriptor.secretnameDefault(declaredRef(name));
      }
      bysecret.computeIfAbsent(secretname, k -> new ArrayList<>()).add(name);
    }

    for (Map.Entry<String, List<String>> plan : bysecret.entrySet()) {
      boolean got;
      try {
        broker.value(plan.getValue().get(0), plan.getKey());
        got = true;
      } catch (RuntimeException ignored) {
        got = false;
      }
      (got ? warmed : missed).addAll(plan.getValue());
    }

    Collections.sort(warmed);
    Collections.sort(missed);
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("warmed", warmed);
    out.put("missed", missed);
    return out;
  }

  /**
   * Every DECLARED instance, sorted by name (design 6.1) - a different
   * question from plugins(), and the answers differ routinely: a lazily
   * started instance is `active: true` and not yet live.
   */
  public synchronized List<Map<String, Object>> instances() {
    Map<String, Object> sdk = Descriptor.asmap(profile.get("sdk"));
    List<Map<String, Object>> out = new ArrayList<>();
    for (String name : new TreeSet<>(sdk.keySet())) {
      Map<String, Object> block = Descriptor.asmap(sdk.get(name));
      PluginEntry entry = registry.get(name);
      Map<String, Object> row = new LinkedHashMap<>();
      row.put("name", name);
      row.put("api", Profile.refapi(name));
      // `active: false` means BARRED FROM RUNNING - a declaration that
      // stays in the file and here while being refused a client.
      row.put("active", !Boolean.FALSE.equals(block.get("active")));
      row.put("live", null != entry);
      row.put("rung", null == entry ? "none" : entry.rung);
      row.put("block", block);
      out.add(row);
    }
    return out;
  }

  // --- the query/observe surface (design 3.2, 6) ---

  /**
   * One entry per LIVE INSTANCE, and EXHAUSTIVE: auto-tagged entries are
   * NOT collapsed here, because inspection, health reporting and cleanup all
   * need to enumerate the clients create() produced, which is exactly when
   * you most want them. Truncation is a presentation decision and belongs
   * to status().
   */
  public synchronized List<Map<String, Object>> plugins() {
    List<Map<String, Object>> out = new ArrayList<>();
    for (PluginEntry entry : registry.values()) {
      Map<String, Object> plugin = new LinkedHashMap<>();
      plugin.put("name", entry.name);
      plugin.put("api", entry.api);
      // Retained: it is the api, which is what `slug` always meant here,
      // and dropping it would break every consumer for no gain while the
      // two are equal for untagged instances.
      plugin.put("slug", entry.api);
      plugin.put("descriptor", entry.descriptor);
      plugin.put("rung", entry.rung);
      plugin.put("secretname", entry.secretname);
      plugin.put("warnings", new ArrayList<>(entry.warnings));
      out.add(plugin);
    }
    return out;
  }

  /**
   * Accepts an INSTANCE name and returns its api's descriptor - one object
   * shared by every instance of that api (design 7.4).
   */
  public synchronized Map<String, Object> descriptorOf(String name) {
    PluginEntry entry = registry.get(name);
    if (null == entry) {
      throw new StationError("station_no_plugin", "unknown plugin \"" + name
          + "\"; known: [" + String.join(", ", registry.keySet()) + "]");
    }
    return entry.descriptor;
  }

  public String canonicalDescriptor(String name) {
    return Descriptor.canonicalSerialize(descriptorOf(name));
  }

  public List<Map<String, Object>> events() {
    return buffer.events();
  }

  public Runnable tap(Consumer<Map<String, Object>> tap) {
    return buffer.tap(tap);
  }

  public synchronized Map<String, Object> status() {
    List<Map<String, Object>> plugins = new ArrayList<>();
    for (PluginEntry entry : registry.values()) {
      Map<String, Object> plugin = new LinkedHashMap<>();
      // Design 7.1: the registry is keyed by INSTANCE, so a status page
      // that projects only `slug` shows two indistinguishable rows for
      // `stripe$test` and `stripe$live` and omits the names it is keyed by -
      // an operator cannot tell which one is unhealthy.
      plugin.put("name", entry.name);
      plugin.put("api", entry.api);
      plugin.put("slug", entry.api);
      plugin.put("rung", entry.rung);
      plugins.add(plugin);
    }

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("mode", "solo");
    out.put("profile", profile.get("name"));
    out.put("plugins", plugins);
    out.put("events", buffer.status());
    return out;
  }

  public String redact(String text) {
    return broker.scrub(text);
  }

  public void refreshSecrets() {
    broker.refresh();
  }

  /**
   * close(): flush (solo: nothing in flight), then warn on declared
   * instances that matched no registered client - a typo'd key silently
   * configuring nothing is the worst outcome for a secrets-and-policy file
   * (design 11).
   */
  public synchronized void close() {
    if (closed) {
      return;
    }
    for (String ref : Descriptor.asmap(profile.get("sdk")).keySet()) {
      if (!registry.containsKey(ref)) {
        warn(null, null, "profile plugin key \"" + ref
            + "\" matched no registered plugin");
      }
    }
    closed = true;
    synchronized (Station.class) {
      if (ambient == this) {
        reset();
      }
    }
  }

  // --- internals ---

  private Map<String, Object> event(String kind, String plugin, String api,
      String corr) {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("t", System.currentTimeMillis());
    out.put("kind", kind);
    // Design 7.3's grouping contract: `plugin` is the INSTANCE and `api` is
    // what groups its siblings, on EVERY kind. Construction events carrying
    // both while runtime events carried only one is grouping that works
    // exactly until it is used.
    if (null != plugin) {
      out.put("plugin", plugin);
    }
    if (null != api) {
      out.put("api", api);
    }
    if (null != corr) {
      out.put("corr", corr);
    }
    return out;
  }

  private void warn(String plugin, String api, String message) {
    Map<String, Object> meta = new LinkedHashMap<>();
    meta.put("warn", message);
    Map<String, Object> event = event("station", plugin, api, null);
    event.put("meta", meta);
    emit(event);
  }

  private void emit(Map<String, Object> event) {
    buffer.emit(event);
  }

  private static String text(Object val) {
    return val instanceof String ? (String) val : null;
  }

  private static String firstNonEmpty(String... vals) {
    for (String val : vals) {
      if (null != val && !val.isEmpty()) {
        return val;
      }
    }
    return null;
  }
}
