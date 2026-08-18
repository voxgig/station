// The bound station side of one plugin (station design 3): the generated
// adapter forwards its hooks and transport calls here, so every rule -
// require fail-closed, hosts policy, injection, event shapes - is the
// library's, never the adapter's.
//
// A port of typescript/src/adapter.ts + the transport middleware of
// Station.ts, which are canonical, arranged along the seam the generated
// Swift SDKs force (see Station.swift's header): the adapter owns the
// physical fetcher wrap and the copy-on-inject deep clone; this class
// owns every decision.

import Foundation

/// What featureBinding() hands back for the adapter to apply - the one
/// mutation set the library cannot perform itself on the SDK's Value
/// maps.
public final class Bound {
  public let binding: Binding
  /// Plant into options.apikey (nil when the plugin's model opted out of
  /// auth - such plugins skip credential planning, design 5.3).
  public let placeholder: String?
  /// Apply to options.base (the profile's per-plugin base, design 3.5
  /// rung 4 - only handed back when the caller's own options carried no
  /// base, so an app-passed base always wins).
  public let base: String?

  init(binding: Binding, placeholder: String?, base: String?) {
    self.binding = binding
    self.placeholder = placeholder
    self.base = base
  }
}

public final class Binding {
  public let slug: String

  private let station: Station
  private let entry: Station.PluginEntry
  private let placeholder: String

  // Per-op correlation state, keyed by the SDK's own op context id:
  // (corr, start ms). Set at PrePoint, consumed at PreDone /
  // PreUnexpected; the transport reads it in between. Keyed by ctx id
  // rather than riding ctx.meta because the generated SDK's meta map is
  // inherited BY REFERENCE from the root context - per-op state stored
  // there would collide across concurrent operations (the rust port's
  // arrangement, for the same reason).
  private var corr: [String: (corr: String, start: Int64)] = [:]
  private let gate = NSLock()

  init(station: Station, entry: Station.PluginEntry) {
    self.station = station
    self.entry = entry
    self.slug = entry.slug
    self.placeholder = SecretBroker.placeholderFor(entry.slug)
  }

  // --- hook bridge (design 3 item 3) ---

  /// PrePoint: open the per-op correlation. The http events the
  /// middleware emits for this op context carry the same corr as the op
  /// event PreDone/PreUnexpected will emit.
  public func opStart(_ ctxId: String) {
    let next = station.nextCorr()
    gate.lock()
    corr[ctxId] = (corr: next, start: Station.now())
    gate.unlock()
  }

  /// The current op's correlation id, if PrePoint opened one (nil on the
  /// direct()/graphql() path, which skips the hook pipeline).
  public func corrOf(_ ctxId: String?) -> String? {
    guard let ctxId = ctxId else { return nil }
    gate.lock()
    defer { gate.unlock() }
    return corr[ctxId]?.corr
  }

  /// PreDone / PreUnexpected: close the op with the outcome the adapter
  /// read from the SDK result ('ok' | 'err' | 'unknown' | 'unexpected').
  public func opDone(_ ctxId: String, _ entity: String, _ opname: String, _ outcome: String) {
    gate.lock()
    let opened = corr.removeValue(forKey: ctxId)
    gate.unlock()

    station.emit(station.event("op", slug, opened?.corr, [
      "op": .map([
        "entity": .str(entity),
        "op": .str(opname),
        "outcome": .str(outcome),
        "durationMs": .num(Double(nil == opened ? 0 : Station.now() - opened!.start)),
      ])
    ]))
  }

  // --- the transport middleware (design 3.3, 5.3) ---

  /// The station middleware body, called by the generated wrap on every
  /// request: policy, injection, and the http event. `live` is whether
  /// the base transport is the real one (mock modes ride through
  /// untouched, so real credentials never enter in-memory mock stores,
  /// design 3.3); `ctxId` correlates with the op events (nil skips
  /// correlation).
  ///
  /// `send` performs the actual request: it receives the full injected
  /// header set (nil when nothing is to change) and the manual-redirect
  /// flag, MUST deep-clone the fetchdef - headers map included - before
  /// applying either (copy-on-inject, design 5.3: the generated request
  /// machinery shares references, fetchdef.headers IS spec.headers and
  /// ctrl.explain holds fetchdef by reference, so the real value only
  /// ever enters the clone), and returns the SDK-shaped response
  /// untouched. `inspect` reads (status, bytes) off that response for
  /// the http event - wire truth, one event per attempt (design 6).
  public func transport<R>(
    _ ctxId: String?,
    _ live: Bool,
    _ fullurl: String,
    _ method: String,
    _ headers: [String: String],
    _ send: (_ injected: [String: String]?, _ manualRedirect: Bool) throws -> R,
    _ inspect: (R) -> (status: Int64, bytes: Int64)
  ) throws -> R {
    let corr = corrOf(ctxId)

    // Fail-closed means traffic (design 2.1): with the proxy deferred,
    // `require` can never attach, so every operation fails here - the
    // operation path, never the constructor.
    if station.requireProxy {
      let noproxy = StationError(
        "station_no_proxy",
        "proxy: \"require\" is set and no proxy is attached")
      station.emitErr(slug, corr, noproxy)
      throw noproxy
    }

    let profilePlugin = station.profilePlugin(slug)

    // Egress policy (design 16), solo half: the hosts allowlist is
    // enforced at the seam every request crosses. When a policy is
    // present, redirects come back manual - a 3xx is a response like any
    // other, so a Location off the allowlist cannot pull an automatic
    // credentialed follow-up to an unapproved host (design 8.2's rule,
    // applied at the library seam).
    let hosts = profilePlugin.get("policy").get("hosts").asList
    let policed = nil != hosts && live

    if let hosts = hosts, live {
      let host = Binding.hostname(fullurl)
      let allowed = hosts.contains { $0.asStr == host }
      if !allowed {
        let denied = StationError(
          "station_host_allow",
          "egress to \"" + host + "\" denied by the hosts policy of plugin \""
            + slug + "\"")
        station.emitErr(slug, corr, denied)
        throw denied
      }
    }

    // Injection: at the last boundary, below every recording feature,
    // and never into mock transports (design 3.3).
    var injected: [String: String]? = nil
    if live && "R1" == entry.rung {
      var secretname = station.secretOverrideOf(slug)
      if nil == secretname || secretname!.isEmpty {
        secretname = profilePlugin.text("secret")
      }
      if nil == secretname || secretname!.isEmpty {
        secretname = entry.descriptor.get("auth").get("secretname").asStr ?? ""
      }

      let value: String
      do {
        value = try station.broker.value(slug, secretname!)
      } catch {
        station.emitErr(slug, corr, error)
        throw error
      }

      var out = headers
      for (name, text) in out where text.contains(placeholder) {
        out[name] = text.replacingOccurrences(of: placeholder, with: value)
      }
      injected = out
    }

    let started = Station.now()

    let res: R
    do {
      res = try send(injected, policed)
    } catch {
      // The attempt is still wire truth (status 0), and the failure
      // enters the event stream scrubbed.
      emitHttp(corr, method, fullurl, started, 0, 0)
      station.emitErr(slug, corr, error)
      throw error
    }

    let (status, bytes) = inspect(res)
    emitHttp(corr, method, fullurl, started, status, bytes)

    return res
  }

  private func emitHttp(
    _ corr: String?, _ method: String, _ fullurl: String,
    _ started: Int64, _ status: Int64, _ bytes: Int64
  ) {
    let (host, path) = Binding.hostAndPath(fullurl)
    var ev = station.event("http", slug, corr, [
      "http": .map([
        "method": .str(method.isEmpty ? "GET" : method),
        "host": .str(host),
        "path": .str(path),
        "status": .num(Double(status)),
        "durationMs": .num(Double(Station.now() - started)),
        "bytes": .num(Double(bytes)),
      ])
    ])
    // The event's t is the attempt's start, not the emit time.
    if case .map(var entries) = ev {
      entries["t"] = .num(Double(started))
      ev = .map(entries)
    }
    station.emit(ev)
  }

  /// The hostname (no port) of a URL, '' when unparseable - the hosts
  /// policy's comparison key, mirroring the canonical port's
  /// `new URL(u).hostname`.
  public static func hostname(_ url: String) -> String {
    let (host, _) = hostAndPath(url)
    if host.hasPrefix("[") {
      // [::1]:8080 - the bracketed form keeps its brackets off.
      return String(host.dropFirst().split(separator: "]").first ?? "")
    }
    return String(host.split(separator: ":").first ?? "")
  }

  /// (host[:port], path) of a URL; ('', url) when unparseable - the http
  /// event's fields, mirroring `new URL(u).host` / `.pathname`.
  static func hostAndPath(_ url: String) -> (String, String) {
    guard let schemeEnd = url.range(of: "://") else {
      return ("", url)
    }
    let rest = url[schemeEnd.upperBound...]
    let hostEnd = rest.firstIndex { "/" == $0 || "?" == $0 || "#" == $0 } ?? rest.endIndex
    let host = String(rest[..<hostEnd])
    let tail = rest[hostEnd...]
    if tail.first == "/" {
      let path = tail.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
      return (host, String(path))
    }
    return (host, "/")
  }
}
