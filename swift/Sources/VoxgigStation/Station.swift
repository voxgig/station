// voxgig/station - one control surface for outbound integrations.
//
// The station library core, solo mode (station design D1): fully
// functional in-process with no other component running. The proxy (D2)
// is a deferred amplifier - `require` therefore fails on the operation
// path (design 2.1/14), and `auto` degrades to solo with one warning
// event.
//
// A port of typescript/src/Station.ts + adapter.ts, which are canonical.
// Swift is an inverted-binding target (design 3.1): the app constructs
// the SDK through its existing generated constructor and hands it
// station-built options. Generated Swift SDKs each vendor their own
// `Value` type and their FetcherFunc is an SDK type, so the physical
// transport wrap lives in the generated adapter and only translated data
// crosses this seam (the rust port's arrangement):
//
//   - featureBinding(...) once at init - the adapter converts the
//     embedded config to Json, hands over the feature-name list for the
//     3.3 wrap-position guard, and applies the returned
//     placeholder/base to its live options map;
//   - Binding.transport(...) per request - the adapter deep-clones its
//     fetchdef before applying the injected header set and the placed
//     URLs (copy-on-inject, design 5.3: the clone is the adapter's ONLY
//     job there; which headers and query values change is decided here);
//   - Binding.opStart()/opDone() from the hook bridge, keyed by the
//     SDK's own per-op context id (design 3 item 3).
//
// SECRETS. There is no Swift sekreto port, so this library is env-only
// for secrets and says so (design 2.2) - see Secrets.swift for the exact
// refusal semantics.

import Foundation

public final class Station {

  // --- ambient instance (design 10.2) ---

  private static var ambient: Station? = nil
  private static var ambientOpts: String? = nil
  private static let ambientGate = NSLock()

  private static var corrSeq: Int64 = 0
  private static let corrGate = NSLock()

  /// open() is the idempotent process-wide singleton; a second open()
  /// with conflicting options is an error; `Station(opts)` stays
  /// isolated for tests and multi-tenant hosts. open() is non-blocking -
  /// solo involves no network, and the deferred proxy probe must never
  /// change that.
  @discardableResult
  public static func open(_ opts: Json? = nil) throws -> Station {
    let key = Descriptor.canonicalSerialize(opts ?? .map([:]))

    ambientGate.lock()
    defer { ambientGate.unlock() }

    if let existing = ambient {
      if key != ambientOpts {
        throw StationError(
          "station_open_conflict",
          "Station.open() was already called with different options")
      }
      return existing
    }

    let station = try Station(opts)
    ambient = station
    ambientOpts = key
    return station
  }

  /// The ambient instance, or nil - never creates one. The generated
  /// station feature binds through this when no explicit handle rides
  /// its options (design 3.1: binding is never implicit; only open()
  /// creates the ambient instance).
  public static func current() -> Station? {
    ambientGate.lock()
    defer { ambientGate.unlock() }
    return ambient
  }

  /// Test seam: drop the ambient instance.
  public static func reset() {
    ambientGate.lock()
    defer { ambientGate.unlock() }
    ambient = nil
    ambientOpts = nil
  }

  /// Resolve the station a feature activation binds to: an explicit
  /// handle (stationOptions() plants one on the feature options as a
  /// native value the adapter reads back), else the ambient instance.
  /// No station open -> nil: an activated feature with no opened station
  /// is an inert no-op that emits nothing and fails nothing (design 3.1).
  public static func from(_ explicit: Station?) -> Station? {
    return explicit ?? current()
  }

  // --- state ---

  final class PluginEntry {
    let slug: String
    let descriptor: Json
    let rung: String
    let client: AnyObject
    let warnings: [String]

    init(slug: String, descriptor: Json, rung: String, client: AnyObject, warnings: [String]) {
      self.slug = slug
      self.descriptor = descriptor
      self.rung = rung
      self.client = client
      self.warnings = warnings
    }
  }

  private let profile: Json
  let broker: SecretBroker
  private let buffer: EventBuffer
  private var registry: [String: PluginEntry] = [:]
  private var order: [String] = []
  var secretOverride: [String: String] = [:]
  let requireProxy: Bool
  private var closed = false
  let gate = NSRecursiveLock()

  // --- construction ---

  /// Options (a Json map): `config` (an in-memory station.json - an
  /// explicit null means "no config file"), `folder` (where the
  /// station.json walk starts), `profile`, `proxy` ('auto' | 'off' |
  /// 'require' | url - the proxy itself is deferred, so anything but
  /// 'require' runs solo).
  public init(_ opts: Json? = nil) throws {
    let o = opts ?? .map([:])

    let config: Json
    if o.has("config") {
      config = o.get("config")
    } else {
      config = (try Profile.loadConfig(o.text("folder"))) ?? .null
    }

    profile = try Profile.resolveProfile(
      config, Profile.selectProfile(o.text("profile")))
    broker = SecretBroker(profile.get("providers"))
    buffer = EventBuffer()

    let proxy = o.text("proxy") ?? "auto"
    requireProxy = "require" == proxy

    if "auto" == proxy {
      // The probe is deferred with the proxy itself; absence degrades to
      // solo with a single warning event naming the cause (design 14).
      warn(nil, "proxy absent (not found); running solo")
    }

    // Env-only honesty (design 2.2): a chain naming stores this port has
    // no sekreto for is SAID, at construction, not discovered at first
    // request.
    let kinds = broker.unsupportedKinds()
    if !kinds.isEmpty {
      warn(
        nil,
        "no swift sekreto port: provider kind(s) "
          + kinds.map { "\"" + $0 + "\"" }.joined(separator: ", ")
          + " are unavailable in solo mode - secrets are env-only (station "
          + "design 2.2), and resolution reaching such a provider fails "
          + "rather than falling through")
    }
  }

  // --- instance refs (design 6.1) ---

  private static let refMax = 1024

  private static func refScalar(_ scalar: Unicode.Scalar, _ marks: String) -> Bool {
    let code = scalar.value
    return (0x30...0x39).contains(code) || (0x41...0x5A).contains(code)
      || (0x61...0x7A).contains(code) || marks.unicodeScalars.contains(scalar)
  }

  public static func checkInstanceName(_ name: String?) -> Bool {
    guard let name = name, let first = name.unicodeScalars.first,
      name.utf16.count <= refMax
    else {
      return false
    }
    let code = first.value
    if !((0x41...0x5A).contains(code) || (0x61...0x7A).contains(code) || 0x40 == code) {
      return false
    }
    return name.unicodeScalars.allSatisfy { refScalar($0, ".~_-/") }
  }

  public static func checkInstanceTag(_ tag: String?) -> Bool {
    guard let tag = tag else {
      return false
    }
    if tag.isEmpty {
      return true
    }
    return tag.utf16.count <= refMax && tag.unicodeScalars.allSatisfy { refScalar($0, ".~_-") }
  }

  /// Validate a ref against the joint grammar and return its canonical
  /// spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
  /// `stripe` are one registry key rather than two.
  public static func checkref(_ ref: String) throws -> String {
    var name = ref
    var tag = ""
    if let cut = ref.firstIndex(of: "$") {
      name = String(ref[..<cut])
      tag = String(ref[ref.index(after: cut)...])
    }
    if !checkInstanceName(name) {
      throw StationError(
        "station_instance_api",
        "invalid instance name \"" + name + "\" in ref \"" + ref + "\": a name "
          + "starts with a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)")
    }
    if !checkInstanceTag(tag) {
      throw StationError(
        "station_instance_api",
        "invalid instance tag \"" + tag + "\" in ref \"" + ref + "\": a tag "
          + "uses `[a-zA-Z0-9.~_-]`, max 1024 (6.1)")
    }
    return tag.isEmpty ? name : ref
  }

  private static func checkapi(_ api: String, _ ref: String) throws -> String {
    if Profile.refapi(ref) != api {
      throw StationError(
        "station_instance_api",
        "instance \"" + ref + "\" names api \"" + Profile.refapi(ref)
          + "\", but the SDK passed is api \"" + api
          + "\"; `as` is a tag, not a free name (6.1)")
    }
    return ref
  }

  /// The instance a binding registers as. `as` is a tag, not a free
  /// name: the api comes from the SDK being built, so the ref is
  /// `api$tag`, and a full ref must name that api. A `$`-less `as` is
  /// always a tag. With no name at all the instance is the SLUG, a name
  /// and never a ref.
  public static func instanceRef(_ api: String, _ fopts: Json) throws -> String {
    if let explicit = fopts.text("instance") {
      return try checkref(checkapi(api, explicit))
    }
    guard let tag = fopts.text("as") else {
      if !checkInstanceName(api) {
        throw StationError(
          "station_instance_api",
          "invalid instance name \"" + api + "\": a name starts with a letter "
            + "or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)")
      }
      return api
    }
    if tag.contains("$") {
      return try checkref(checkapi(api, tag))
    }
    return try checkref(api + "$" + tag)
  }

  /// The ref a caller names before construction: an explicit instance,
  /// or an `as` that is a full ref. A bare tag needs the SDK's api, and
  /// an invalid name is left for registration to refuse.
  public static func namedRef(_ fopts: Json) -> String? {
    var name = fopts.text("instance")
    if nil == name, let tag = fopts.text("as"), tag.contains("$") {
      name = tag
    }
    guard let ref = name else {
      return nil
    }
    return try? checkref(ref)
  }

  // --- inverted binding (design 3.1) ---

  /// Build the plain options entries a generated constructor's options
  /// map carries: the caller's options plus the station activation entry
  /// carrying this handle. The generated station feature performs
  /// registration and credential placement during construction. The
  /// generated adapter ships a `stationOptions()` sugar that builds the
  /// SDK's own Value-map form of exactly this shape (the library cannot
  /// construct a generated SDK's value types).
  ///
  /// The instance name is optional and leading (6.1): the named instance
  /// - the leading name, else a top-level `instance` or full-ref `as`,
  /// else the station entry's own - is constructed with its block's
  /// `options` and `base` under the caller's options, one top-level key
  /// at a time (3.5). Unnamed, the profile's base is applied at binding
  /// time, when the slug is known.
  public func options(_ extra: [String: Any?]? = nil) -> [String: Any?] {
    return built(nil, extra ?? [:])
  }

  public func options(_ instance: String, _ extra: [String: Any?]? = nil) -> [String: Any?] {
    return built(instance, extra ?? [:])
  }

  /// The block defaults a named instance is constructed with - its
  /// `options`, then its `base` (3.5) - for the caller's own options to
  /// go over, key by key; nil when `named` names no instance before
  /// construction. The generated adapter's stationOptions() reads it.
  public func instanceDefaults(_ named: Json) -> Json? {
    guard let ref = Station.namedRef(named) else {
      return nil
    }
    return Profile.instanceOptions(Profile.blockOf(profile, ref), .map([:]))
  }

  private func built(_ instance: String?, _ given: [String: Any?]) -> [String: Any?] {
    var names: [String: String] = [:]
    for key in ["as", "instance"] {
      if let text = given[key] as? String {
        names[key] = text
      }
    }
    if let instance = instance, !instance.isEmpty {
      names["instance"] = instance
    }

    let fentry = ((given["feature"] as? [String: Any?])?["station"] as? [String: Any?]) ?? [:]
    var named: [String: Json] = [:]
    for key in ["as", "instance"] {
      if let text = fentry[key] as? String {
        named[key] = .str(text)
      }
    }
    for (key, text) in names {
      named[key] = .str(text)
    }

    var calleropts = given
    if let defaults = instanceDefaults(.map(named))?.asMap {
      calleropts = [:]
      for (key, val) in defaults {
        calleropts.updateValue(Station.native(val), forKey: key)
      }
      for (key, val) in given {
        calleropts.updateValue(val, forKey: key)
      }
    }

    var out = calleropts
    out.removeValue(forKey: "as")
    out.removeValue(forKey: "instance")

    var fmap = (out["feature"] as? [String: Any?]) ?? [:]
    var entry = (fmap["station"] as? [String: Any?]) ?? [:]
    entry["active"] = true
    entry["station"] = self
    entry["calleropts"] = calleropts
    for (key, text) in names {
      entry[key] = text
    }
    fmap["station"] = entry
    out["feature"] = fmap

    return out
  }

  /// A Json value in the native form options() hands back.
  static func native(_ json: Json) -> Any? {
    switch json {
    case .null:
      return nil
    case .bool(let flag):
      return flag
    case .num(let num):
      return num
    case .str(let text):
      return text
    case .list(let items):
      return items.map { native($0) }
    case .map(let entries):
      var out: [String: Any?] = [:]
      for (key, entry) in entries {
        out.updateValue(native(entry), forKey: key)
      }
      return out
    }
  }

  // --- the binding seam (design 3, called by the generated adapter) ---

  /// The station side of the plugin contract (design 3), in ONE place -
  /// the Swift spelling of the ts library's featureBinding(). The
  /// generated StationFeature calls it from initFeature() with the
  /// pieces the library cannot reach through generated types: the client
  /// handle, the feature names in add order, the embedded config and
  /// options.feature map (as Json), its own feature options (as Json -
  /// `calleropts` included when stationOptions() built them), and the
  /// resident options.apikey.
  ///
  /// Registration at init, wrap position verified, credential
  /// placeholder planned (a resident credential is hoisted), returns the
  /// instructions the adapter applies - or nil when this client is
  /// already bound (same construction, second arrival must no-op; a
  /// genuinely second client of the same SDK class still fails the slug
  /// check, design 10.2).
  public func featureBinding(
    _ client: AnyObject,
    _ featureNames: [String],
    _ config: Json,
    _ activeFeatures: Json,
    _ featureOpts: Json,
    _ residentApikey: String
  ) throws -> Bound? {
    gate.lock()
    defer { gate.unlock() }

    if nil != boundEntry(client) {
      return nil
    }

    // Position guard (design 3.3): the wrap must sit immediately outside
    // the base transport - inside retry/cache/ratelimit - or its http
    // events stop being wire truth. Position in client.features IS init
    // order, so verify it and fail loudly. One generated-SDK adjustment:
    // makeFeature's default case absorbs an unknown activation name as
    // an inert BaseFeature (name "base") instead of throwing, so a stray
    // "base" entry can sit anywhere in the list without wrapping
    // anything - expected position is computed with those inert slots
    // skipped, not from raw adjacency.
    let names = featureNames.filter { "base" != $0 }
    let selfAt = names.firstIndex(of: "station")
    let testAt = names.firstIndex(of: "test")
    let expected = nil == testAt ? 0 : testAt! + 1
    if selfAt != expected {
      throw StationError(
        "station_wrap_order",
        "station must init immediately after the base transport; feature "
          + "order is [" + featureNames.joined(separator: ", ") + "]")
    }

    let (descriptor, warnings) = Descriptor.normalizeDescriptor(config, activeFeatures)

    // Design 7.5: the instance named before construction rides the
    // feature options; a bare binding is the descriptor slug.
    let slug = try Station.instanceRef(descriptor.get("slug").asStr ?? "", featureOpts)

    if nil != registry[slug] {
      throw StationError(
        "station_bound_twice",
        "instance \"" + slug + "\" is already registered; binding one client "
          + "twice is an error (design 10.2)")
    }

    let profilePlugin = Profile.blockOf(profile, slug)

    // Secret name precedence: the feature option (in-code, design 9
    // config.options.secret) beats the profile, which beats the
    // instance-derived default (an untagged instance's is the
    // descriptor's own).
    if let foptSecret = featureOpts.text("secret") {
      secretOverride[slug] = foptSecret
    }

    let authActive = true == descriptor.get("auth").get("active").asBool
    let rung = authActive ? "R1" : "none"

    registry[slug] = PluginEntry(
      slug: slug, descriptor: descriptor, rung: rung, client: client,
      warnings: warnings)
    order.append(slug)

    for warning in warnings {
      warn(slug, warning)
    }
    emit(event("construct", slug, nil, [
      "meta": .map([
        "name": descriptor.get("name"),
        "version": descriptor.get("version"),
        "rung": .str(rung),
      ])
    ]))

    // Base URL precedence (design 3.5): caller opts (7) beat the profile
    // (4), which beats the SDK's config default (1) already in
    // options.base. `calleropts` is what stationOptions() was handed, so
    // an explicit caller base wins; without the marker (hand-written
    // map-form activation) the profile base is conservatively NOT
    // applied.
    var base: String? = nil
    if let calleropts = featureOpts.get("calleropts").asMap,
      nil == calleropts["base"],
      let profileBase = profilePlugin.text("base")
    {
      base = profileBase
    }

    var placeholder: String? = nil
    if "none" != rung {
      let plant = SecretBroker.placeholderFor(slug)
      placeholder = plant

      // A real credential already resident in the options is hoisted
      // into the broker and replaced by the placeholder before
      // construction completes (design 3.1 adopt) - optionsMap() and
      // prepare() output become placeholder-safe from here on.
      if !residentApikey.isEmpty && plant != residentApikey {
        broker.hoist(slug, residentApikey)
        warn(
          slug,
          "a resident credential was hoisted into the broker and replaced "
            + "by the placeholder; prefer configuring the secret name and "
            + "letting the provider chain resolve it")
      }
    }

    let binding = Binding(station: self, entry: registry[slug]!)

    return Bound(binding: binding, placeholder: placeholder, base: base)
  }

  /// A fresh per-operation correlation id (design 3 item 3).
  public func nextCorr() -> String {
    Station.corrGate.lock()
    defer { Station.corrGate.unlock() }
    Station.corrSeq += 1
    return "c\(Station.corrSeq)"
  }

  private func boundEntry(_ client: AnyObject) -> PluginEntry? {
    for slug in order {
      if let entry = registry[slug], entry.client === client {
        return entry
      }
    }
    return nil
  }

  func profilePlugin(_ slug: String) -> Json {
    gate.lock()
    defer { gate.unlock() }
    return Profile.blockOf(profile, slug)
  }

  func secretOverrideOf(_ slug: String) -> String? {
    gate.lock()
    defer { gate.unlock() }
    return secretOverride[slug]
  }

  // --- the query/observe surface (design 3.2, 6) ---

  public func plugins() -> [Json] {
    gate.lock()
    defer { gate.unlock() }
    return order.compactMap { slug in
      guard let entry = registry[slug] else { return nil }
      return .map([
        "slug": .str(entry.slug),
        "descriptor": entry.descriptor,
        "rung": .str(entry.rung),
        "warnings": .list(entry.warnings.map { .str($0) }),
      ])
    }
  }

  public func descriptorOf(_ slug: String) throws -> Json {
    gate.lock()
    defer { gate.unlock() }
    guard let entry = registry[slug] else {
      throw StationError(
        "station_no_plugin",
        "unknown plugin \"" + slug + "\"; known: ["
          + order.joined(separator: ", ") + "]")
    }
    return entry.descriptor
  }

  public func canonicalDescriptor(_ slug: String) throws -> String {
    return Descriptor.canonicalSerialize(try descriptorOf(slug))
  }

  public func events() -> [Json] {
    return buffer.events()
  }

  public func tap(_ tap: @escaping (Json) -> Void) -> () -> Void {
    return buffer.tap(tap)
  }

  public func status() -> Json {
    gate.lock()
    defer { gate.unlock() }
    let plugins: [Json] = order.compactMap { slug in
      guard let entry = registry[slug] else { return nil }
      return .map(["slug": .str(entry.slug), "rung": .str(entry.rung)])
    }
    return .map([
      "mode": .str("solo"),
      "profile": profile.get("name"),
      "plugins": .list(plugins),
      "events": buffer.status(),
    ])
  }

  public func redact(_ text: String) -> String {
    return broker.scrub(text)
  }

  public func refreshSecrets() {
    broker.refresh()
  }

  /// close(): flush (solo: nothing in flight), then warn on profile
  /// plugin keys that matched no registered plugin - a typo'd key
  /// silently configuring nothing is the worst outcome for a
  /// secrets-and-policy file (design 11).
  public func close() {
    gate.lock()
    if !closed {
      if let entries = profile.get("sdk").asMap {
        for slug in Descriptor.sortedKeys(entries) where nil == registry[slug] {
          warn(nil, "profile plugin key \"" + slug + "\" matched no registered plugin")
        }
      }
      closed = true
    }
    gate.unlock()

    Station.ambientGate.lock()
    if Station.ambient === self {
      Station.ambient = nil
      Station.ambientOpts = nil
    }
    Station.ambientGate.unlock()
  }

  // --- internals (shared with Binding) ---

  func event(
    _ kind: String, _ plugin: String?, _ corr: String?,
    _ extra: [String: Json] = [:]
  ) -> Json {
    var out: [String: Json] = [
      "t": .num(Double(Station.now())),
      "kind": .str(kind),
    ]
    if let plugin = plugin {
      out["plugin"] = .str(plugin)
    }
    if let corr = corr {
      out["corr"] = .str(corr)
    }
    for (key, val) in extra {
      out[key] = val
    }
    return .map(out)
  }

  func warn(_ plugin: String?, _ message: String) {
    emit(event("station", plugin, nil, ["meta": .map(["warn": .str(message)])]))
  }

  func emit(_ ev: Json) {
    buffer.emit(ev)
  }

  func emitErr(_ slug: String?, _ corr: String?, _ err: Error) {
    var errmap: [String: Json] = [:]
    if let serr = err as? StationError {
      errmap["code"] = .str(serr.code)
    }
    // The scrub keeps an upstream echo of a credential out of the event
    // stream (design 7 as revised: exact-value, no length floor).
    errmap["message"] = .str(broker.scrub(errMessage(err)))
    emit(event("error", slug, corr, ["err": .map(errmap)]))
  }

  static func now() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000)
  }
}

func errMessage(_ err: Error) -> String {
  if let serr = err as? StationError {
    return serr.message
  }
  return "\(err)"
}
