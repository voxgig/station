// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the VoxgigStation library
// (station design 2); Station.featureBinding resolves nothing from here:
// this file only translates the generated SDK's concrete types (Value,
// VMap, Context, FetcherFunc) into the library's featureBinding /
// Binding.transport seams - never restate a binding rule here. The one
// physical duty the type boundary leaves on this side is the
// copy-on-inject clone (station design 5.3): the fetchdef is deep-cloned
// BEFORE the injected header set is applied, so the object graph
// reachable from ctx/spec/ctrl.explain keeps only the placeholder, ever
// (fetchdef.headers IS spec.headers by reference - Make.swift).
//
// The station handle rides the feature options as a native value
// (stationOptions() below plants it); with no handle the adapter binds
// to the ambient Station.current(), and with no station open at all the
// feature is an inert no-op (station design 3.1). Misbinding - wrong
// wrap position, one client bound twice - fails loudly at construction
// (the library throws the catalog code; construction-time
// misconfiguration is fatal, the generated SDKs' idiom).

import Foundation
import VoxgigStation

public final class StationFeature: BaseFeature {
  private var binding: VoxgigStation.Binding?

  public override init() {
    super.init()
    version = "0.0.1"
    name = "station"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    active = foptBool(options, "active", false)
    if !active {
      return
    }

    guard
      let st = Station.from(gp(options, "station").asNative as? Station),
      let client = ctx.client,
      let utility = ctx.utility,
      let clientOptions = ctx.options
    else {
      return
    }

    // The client's feature list by name, in add order (= init order) -
    // the wrap-position guard's input (station design 3.3).
    let names = client.features.map { $0.getName() }

    let bound: Bound?
    do {
      bound = try st.featureBinding(
        client,
        names,
        stationValueJson(.map(ctx.config ?? VMap())),
        stationValueJson(gp(clientOptions, "feature")),
        stationValueJson(.map(options)),
        gp(clientOptions, "apikey").asString ?? "")
    } catch {
      fatalError(String(describing: error))
    }

    // Same construction, second arrival: inert (station design 10.2).
    guard let bound = bound else {
      return
    }

    // Apply the binding's instruction set to the live options map (shared
    // with the client and every context): the profile base (station
    // design 3.5) and the credential placeholder - prepareAuth then
    // emits the placeholder, and the transport swaps in the real value at
    // send time, below every recording feature.
    if let base = bound.base {
      clientOptions.entries["base"] = .string(base)
    }
    if let placeholder = bound.placeholder {
      clientOptions.entries["apikey"] = .string(placeholder)
    }

    let binding = bound.binding
    self.binding = binding

    // Wrap the transport: clone-and-replace like every transport feature
    // (RetryFeature's pattern). Position = init order, already verified.
    let inner = utility.fetcher!
    utility.fetcher = { ctx2, fullurl, fetchdef in
      try stationTransport(binding, inner, ctx2, fullurl, fetchdef)
    }
  }

  // Hook bridge (station design 3 item 3): operation semantics
  // correlated with the http events via the op context's own id (this
  // SDK's ctx.meta is inherited by reference from the root context, so
  // per-op state cannot ride it).

  public override func prePoint(_ ctx: Context) {
    binding?.opStart(ctx.id)
  }

  public override func preDone(_ ctx: Context) {
    guard let binding = binding else { return }
    let (entity, opname) = stationOpIdentity(ctx)
    binding.opDone(ctx.id, entity, opname, stationOutcome(ctx))
  }

  public override func preUnexpected(_ ctx: Context) {
    guard let binding = binding else { return }
    let (entity, opname) = stationOpIdentity(ctx)
    binding.opDone(ctx.id, entity, opname, "unexpected")
  }
}

// The inverted-binding sugar (station design 3.1): build the plain
// options map the generated constructor already accepts - the caller's
// options plus the station activation entry carrying the handle. The
// library's Station.options() is this same shape in native form; the
// spelling lives here because the library cannot construct this SDK's
// Value maps. `calleropts` marks what the caller passed, so an explicit
// caller base wins over the profile's (station design 3.5).
public func stationOptions(_ station: Station? = nil, _ extra: VMap? = nil) -> VMap {
  let calleropts = extra ?? VMap()

  let out = VMap()
  for (k, v) in calleropts.entries {
    out.entries[k] = v
  }

  let fmap = VMap()
  if let fm = out.entries["feature"]?.asMap {
    for (k, v) in fm.entries {
      fmap.entries[k] = v
    }
  }

  let entry = VMap()
  if let em = fmap.entries["station"]?.asMap {
    for (k, v) in em.entries {
      entry.entries[k] = v
    }
  }
  entry.entries["active"] = .bool(true)
  if let station = station {
    entry.entries["station"] = .nat(station)
  }
  entry.entries["calleropts"] = .map(calleropts)

  fmap.entries["station"] = .map(entry)
  out.entries["feature"] = .map(fmap)

  return out
}

// The transport middleware shell: extract what the library's per-request
// decisions need, apply its plan, return the SDK-shaped response
// untouched. All decisions (require, hosts policy, injection, event
// shapes) are the library's; the deep clone below is this SDK's one
// physical duty (copy-on-inject, station design 5.3).
private func stationTransport(
  _ binding: VoxgigStation.Binding, _ inner: @escaping FetcherFunc,
  _ ctx: Context, _ fullurl: String, _ fetchdef: VMap
) throws -> Value {
  let live = ctx.client?.mode == "live"

  var headers: [String: String] = [:]
  if let hm = gp(fetchdef, "headers").asMap {
    for (k, v) in hm.entries {
      if let text = v.asString {
        headers[k] = text
      }
    }
  }

  var method = gp(fetchdef, "method").asString ?? ""
  if method.isEmpty {
    method = "GET"
  }

  do {
    return try binding.transport(
      ctx.id, live, fullurl, method, headers,
      { injected, manualRedirect in
        var senddef = fetchdef
        if nil != injected || manualRedirect {
          let cloned = clone(.map(fetchdef)).asMap ?? VMap()
          if let injected = injected {
            let hm = cloned.entries["headers"]?.asMap ?? VMap()
            for (k, v) in injected {
              hm.entries[k] = .string(v)
            }
            cloned.entries["headers"] = .map(hm)
          }
          if manualRedirect {
            // In-band annotation on the sent copy only: with a hosts
            // policy, redirects come back manual (station design 8.2).
            cloned.entries["redirect"] = .string("manual")
          }
          senddef = cloned
        }
        return try inner(ctx, fullurl, senddef)
      },
      { res in
        let (status, _) = fresStatus(res)
        let (lenText, hasLen) = fresHeader(res, "content-length")
        let bytes = hasLen ? fparseInt(lenText, 0) : 0
        return (Int64(status), Int64(bytes))
      })
  } catch let err as StationError {
    // Surface the failure through the SDK's own error path with the
    // catalog code intact (the library already emitted the error event).
    throw ctx.makeError(err.code, err.message)
  }
}

// The op identity from the SDK context - the one extraction the type
// boundary keeps out of the library ("_" is this SDK's unset marker).
private func stationOpIdentity(_ ctx: Context) -> (String, String) {
  var entity = ctx.op?.entity ?? ""
  var opname = ctx.op?.name ?? ""
  if "_" == entity { entity = "" }
  if "_" == opname { opname = "" }
  if entity.isEmpty, let ent = ctx.entity {
    entity = ent.getName()
  }
  return (entity, opname)
}

private func stationOutcome(_ ctx: Context) -> String {
  guard let result = ctx.result else {
    return "unknown"
  }
  if nil != result.err || !result.ok {
    return "err"
  }
  return "ok"
}

// The SDK's Value tree as the station library's Json (functions and
// native values dropped, absent markers as null) - the embedded config
// and options cross the seam once, at init.
private func stationValueJson(_ val: Value) -> VoxgigStation.Json {
  switch val {
  case .bool(let flag):
    return .bool(flag)
  case .int(let num):
    return .num(Double(num))
  case .double(let num):
    return .num(num)
  case .string(let text):
    return .str(text)
  case .list(let items):
    return .list(items.items.map(stationValueJson))
  case .map(let entries):
    var out: [String: VoxgigStation.Json] = [:]
    for (key, entry) in entries.entries {
      switch entry {
      case .function, .native, .sentinel:
        continue
      default:
        out[key] = stationValueJson(entry)
      }
    }
    return .map(out)
  default:
    return .null
  }
}
