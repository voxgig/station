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

package com.voxgig.station;

import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

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
    final String slug;
    final Map<String, Object> descriptor;
    final String rung;
    final Object client;
    final List<String> warnings;

    PluginEntry(String slug, Map<String, Object> descriptor, String rung,
        Object client, List<String> warnings) {
      this.slug = slug;
      this.descriptor = descriptor;
      this.rung = rung;
      this.client = client;
      this.warnings = warnings;
    }
  }

  private final Map<String, Object> opts;
  private final Map<String, Object> profile;
  private final SecretBroker broker;
  private final EventBuffer buffer;
  private final Map<String, PluginEntry> registry = new LinkedHashMap<>();
  private final Map<String, String> secretOverride = new LinkedHashMap<>();
  private final boolean requireProxy;
  private boolean closed = false;

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
      warn(null, "proxy absent (not found); running solo");
    }
  }

  // --- inverted binding (design 3.1) ---

  /**
   * Build the plain options map a generated constructor already accepts:
   * the caller's options plus the station activation entry carrying this
   * handle. The generated station feature performs registration and
   * credential placement during construction; the profile's per-plugin
   * base is applied at binding time, when the slug is known.
   */
  public Map<String, Object> options() {
    return options(null);
  }

  public Map<String, Object> options(Map<String, Object> extra) {
    Map<String, Object> calleropts = null == extra ? new LinkedHashMap<>() : extra;
    Map<String, Object> out = new LinkedHashMap<>(calleropts);

    Map<String, Object> fmap = new LinkedHashMap<>(
        Descriptor.asmap(out.get("feature")));
    Map<String, Object> entry = new LinkedHashMap<>(
        Descriptor.asmap(fmap.get("station")));
    entry.put("active", true);
    entry.put("station", this);
    entry.put("calleropts", calleropts);
    fmap.put("station", entry);
    out.put("feature", fmap);

    return out;
  }

  // --- the binding seam (design 3, called by the generated adapter) ---

  /**
   * The station side of the plugin contract (design 3), in ONE place -
   * the java spelling of the ts library's featureBinding(). The generated
   * StationFeature calls it from init() with the pieces the library
   * cannot reach through generated types: the client handle, the feature
   * names in add order, the current transport slot value, the embedded
   * config, the resolved options, and its own feature options.
   *
   * Registration at init, wrap position verified, credential placeholder
   * planted (a resident credential is hoisted), returns the binding - or
   * null when this client is already bound (same construction, second
   * arrival must no-op; a genuinely second client of the same SDK class
   * still fails the slug check, design 10.2).
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

    Descriptor.Normalized normalized = Descriptor.normalizeDescriptor(
        config, null == options ? null : options.get("feature"));
    Map<String, Object> descriptor = normalized.descriptor;
    String slug = (String) descriptor.get("slug");

    if (registry.containsKey(slug)) {
      throw new StationError("station_bound_twice",
          "plugin \"" + slug + "\" is already registered; binding one client "
              + "twice is an error (design 10.2)");
    }

    Map<String, Object> profilePlugin = Descriptor.asmap(
        Descriptor.getprop(profile.get("sdk"), slug));

    // Secret name precedence: the feature option (in-code, design 9
    // config.options.secret) beats the profile, which beats the
    // descriptor default.
    Map<String, Object> auth = Descriptor.asmap(descriptor.get("auth"));
    String foptSecret = text(null == fopts ? null : fopts.get("secret"));
    String secretname = firstNonEmpty(foptSecret,
        text(profilePlugin.get("secret")));
    if (null == secretname) {
      secretname = (String) auth.get("secretname");
    }
    if (null != foptSecret) {
      secretOverride.put(slug, foptSecret);
    }

    boolean authActive = Boolean.TRUE.equals(auth.get("active"));
    String rung = authActive ? "R1" : "none";

    Map<String, Object> binding = new LinkedHashMap<>();
    binding.put("plugin", slug);
    if (authActive) {
      binding.put("placeholder", SecretBroker.placeholderFor(slug));
      binding.put("secretname", secretname);
    }
    binding.put("rung", rung);

    registry.put(slug, new PluginEntry(
        slug, descriptor, rung, client, normalized.warnings));

    for (String warning : normalized.warnings) {
      warn(slug, warning);
    }
    Map<String, Object> meta = new LinkedHashMap<>();
    meta.put("name", descriptor.get("name"));
    meta.put("version", descriptor.get("version"));
    meta.put("rung", rung);
    Map<String, Object> event = event("construct", slug, null);
    event.put("meta", meta);
    emit(event);

    // Base URL precedence (design 3.5): caller opts (7) beat the profile
    // (4), which beats the SDK's config default (1) already in
    // options.base. calleropts is what st.options() was handed, so an
    // explicit caller base wins.
    Object calleropts = null == fopts ? null : fopts.get("calleropts");
    if (calleropts instanceof Map && null != options
        && null == ((Map<String, Object>) calleropts).get("base")
        && null != profilePlugin.get("base")) {
      options.put("base", profilePlugin.get("base"));
    }

    if (!"none".equals(rung) && null != options) {
      String placeholder = SecretBroker.placeholderFor(slug);

      // A real credential already resident in the options is hoisted into
      // the broker and replaced by the placeholder before construction
      // completes (design 3.1 adopt) - options() and prepare() output
      // become placeholder-safe from here on.
      Object resident = options.get("apikey");
      if (resident instanceof String && !((String) resident).isEmpty()
          && !placeholder.equals(resident)) {
        broker.hoist(slug, (String) resident);
        warn(slug, "a resident credential was hoisted into the broker and "
            + "replaced by the placeholder; prefer configuring the secret "
            + "name and letting sekreto resolve it");
      }
      options.put("apikey", placeholder);
    }

    // Double-wrap guard: a station wrap already on the transport slot
    // means another Station instance bound this client (the same
    // instance no-ops above).
    if (isStationTransport(currentTransport)) {
      throw new StationError("station_bound_twice",
          "plugin \"" + slug + "\" already carries a station wrap");
    }

    return binding;
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

  // --- the transport middleware (design 3.3, 5.3) ---

  /**
   * The station middleware body, called by the generated wrap on every
   * request: policy, injection with copy-on-inject, and the http event.
   * `live` is whether the base transport is the real one (mock modes ride
   * through untouched, so real credentials never enter in-memory mock
   * stores, design 3.3); `corr` is the per-operation id the hook bridge
   * planted, null on the direct()/graphql() path.
   */
  public Object transport(String slug, String fullurl,
      Map<String, Object> fetchdef, boolean live, String corr,
      Transport inner) {

    // Fail-closed means traffic (design 2.1): with the proxy deferred,
    // `require` can never attach, so every operation fails here - the
    // operation path, never the constructor.
    if (requireProxy) {
      StationError err = new StationError("station_no_proxy",
          "proxy: \"require\" is set and no proxy is attached");
      emitErr(slug, corr, err);
      throw err;
    }

    PluginEntry entry;
    synchronized (this) {
      entry = registry.get(slug);
    }
    String placeholder = SecretBroker.placeholderFor(slug);
    Map<String, Object> profilePlugin = Descriptor.asmap(
        Descriptor.getprop(profile.get("sdk"), slug));

    // Egress policy (design 16), solo half: the hosts allowlist is
    // enforced at the seam every request crosses. When a policy is
    // present, redirects come back manual - a 3xx is a response like any
    // other, so a Location off the allowlist cannot pull an automatic
    // credentialed follow-up to an unapproved host (design 8.2's rule,
    // applied at the library seam).
    Object hosts = Descriptor.getprop(profilePlugin.get("policy"), "hosts");
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
                + "plugin \"" + slug + "\"");
        emitErr(slug, corr, err);
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
      String secretname;
      synchronized (this) {
        secretname = firstNonEmpty(secretOverride.get(slug),
            text(profilePlugin.get("secret")));
      }
      if (null == secretname) {
        secretname = (String) Descriptor.getprop(
            entry.descriptor.get("auth"), "secretname");
      }

      String value;
      try {
        value = broker.value(slug, secretname);
      } catch (StationError err) {
        emitErr(slug, corr, err);
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
      emitHttp(slug, corr, fullurl, senddef, 0, started, 0);
      emitErr(slug, corr, err);
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
    emitHttp(slug, corr, fullurl, senddef, status, started, bytes);

    return res;
  }

  /** Op events from the hook bridge (design 3 item 3). */
  public void opEvent(String slug, String corr, Long start,
      String entity, String opname, String outcome) {
    Map<String, Object> op = new LinkedHashMap<>();
    op.put("entity", null == entity ? "" : entity);
    op.put("op", null == opname ? "" : opname);
    op.put("outcome", outcome);
    op.put("durationMs", null == start ? 0L
        : System.currentTimeMillis() - start);

    Map<String, Object> event = event("op", slug, corr);
    event.put("op", op);
    emit(event);
  }

  private void emitHttp(String slug, String corr, String fullurl,
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
    event.put("plugin", slug);
    if (null != corr) {
      event.put("corr", corr);
    }
    event.put("http", http);
    emit(event);
  }

  private void emitErr(String slug, String corr, RuntimeException err) {
    Map<String, Object> errmap = new LinkedHashMap<>();
    if (err instanceof StationError) {
      errmap.put("code", ((StationError) err).code);
    }
    // The scrub keeps an upstream echo of a credential out of the event
    // stream (design 7 as revised: exact-value, no length floor).
    String message = null == err.getMessage()
        ? String.valueOf(err) : err.getMessage();
    errmap.put("message", redact(message));

    Map<String, Object> event = event("error", slug, corr);
    event.put("err", errmap);
    emit(event);
  }

  // --- the query/observe surface (design 3.2, 6) ---

  public synchronized List<Map<String, Object>> plugins() {
    List<Map<String, Object>> out = new ArrayList<>();
    for (PluginEntry entry : registry.values()) {
      Map<String, Object> plugin = new LinkedHashMap<>();
      plugin.put("slug", entry.slug);
      plugin.put("descriptor", entry.descriptor);
      plugin.put("rung", entry.rung);
      plugin.put("warnings", new ArrayList<>(entry.warnings));
      out.add(plugin);
    }
    return out;
  }

  public synchronized Map<String, Object> descriptorOf(String slug) {
    PluginEntry entry = registry.get(slug);
    if (null == entry) {
      throw new StationError("station_no_plugin", "unknown plugin \"" + slug
          + "\"; known: [" + String.join(", ", registry.keySet()) + "]");
    }
    return entry.descriptor;
  }

  public String canonicalDescriptor(String slug) {
    return Descriptor.canonicalSerialize(descriptorOf(slug));
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
      plugin.put("slug", entry.slug);
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
   * close(): flush (solo: nothing in flight), then warn on profile plugin
   * keys that matched no registered plugin - a typo'd key silently
   * configuring nothing is the worst outcome for a secrets-and-policy
   * file (design 11).
   */
  public synchronized void close() {
    if (closed) {
      return;
    }
    for (String slug : Descriptor.asmap(profile.get("sdk")).keySet()) {
      if (!registry.containsKey(slug)) {
        warn(null, "profile plugin key \"" + slug
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

  private Map<String, Object> event(String kind, String plugin, String corr) {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("t", System.currentTimeMillis());
    out.put("kind", kind);
    if (null != plugin) {
      out.put("plugin", plugin);
    }
    if (null != corr) {
      out.put("corr", corr);
    }
    return out;
  }

  private void warn(String plugin, String message) {
    Map<String, Object> meta = new LinkedHashMap<>();
    meta.put("warn", message);
    Map<String, Object> event = event("station", plugin, null);
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
