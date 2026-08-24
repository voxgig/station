// The station side of the plugin contract (design §3), in ONE place:
// featureBinding() is what both entry paths delegate to -
//  - the GENERATED station feature (sdkgen-station's js template) calls
//    it from its init() and forwards its hook methods;
//  - the library's carried adapter (adapterFeature, the adopt/connect
//    retrofit for SDKs generated without the feature) is a thin shell
//    over the same call.
// Registration at init, wrap position verified, transport wrapped with
// copy-on-inject, hooks bridged to op events. Anything changed here
// changes both paths - which is the point.
//
// A port of typescript/src/adapter.ts, which is canonical.

const { StationError } = require('./error')
const { Station } = require('./Station')

let corrSeq = 0

// Resolve the station this activation binds to: an explicit handle in
// the feature options (connect/adopt and st.options() pass one), else
// the ambient instance. No station open -> null: an activated feature
// with no opened station is an inert no-op that emits nothing and
// fails nothing (design §3.1).
function featureBinding(ctx, fopts) {
  const station =
    (fopts?.station instanceof Station ? fopts.station : null) ?? Station.current()
  if (null == station) { return null }

  const client = ctx.client

  // Same construction, second arrival (generated feature + carried
  // adapter both active on one client): the first bind won, this one
  // is inert. See Station._boundEntry.
  if (null != station._boundEntry(client)) { return null }
  const utility = ctx.utility
  const options = ctx.options
  const calleropts = fopts?.calleropts

  // Position guard (design §3.3): the wrap must sit immediately
  // outside the base transport - inside retry/cache/ratelimit - or
  // its http events stop being wire truth. Position in
  // client._features IS init order, so verify it and fail loudly.
  const names = client._features.map((f) => f.name)
  const self = names.indexOf('station')
  const testAt = names.indexOf('test')
  const expected = -1 === testAt ? 0 : testAt + 1
  if (self !== expected) {
    throw new StationError('station_wrap_order',
      'station must init immediately after the base transport; ' +
      'feature order is [' + names.join(', ') + ']')
  }

  // §7.5: registration is driven by station now. `fopts.instance` is
  // where station puts the instance name it knew before construction
  // began; `_register` reads it and falls back to the descriptor slug,
  // which is today's behaviour for a bare connect(SDK).
  const reg = station._register(client, ctx.config, options, calleropts, fopts)
  const { binding, profilePlugin } = reg
  // The INSTANCE name, not the api slug. Everything below keys on it -
  // the placeholder, the transport seam, the op events - because two
  // live instances of one api must be distinguishable at each.
  const name = binding.plugin

  // Base URL precedence (design §3.5): caller opts (7) beat the
  // profile (4), which beats the SDK's config default (1) already in
  // options.base. Applied only on the connect/adopt path, where the
  // caller opts are knowable; station.options() applies the profile
  // base at options-build time instead.
  if (null != calleropts && null == calleropts.base && null != profilePlugin?.base) {
    options.base = profilePlugin.base
  }

  // Policy allowlists (design §16): `allow.op` / `allow.method` are
  // "the same vocabulary the SDKs already enforce (`options.allow`, and
  // the raw-access gate every target implements); station sets these
  // SDK options from policy so enforcement is in the SDK's own
  // pipeline" - the point_op_allow / spec_method_allow gates. The SDK's
  // own option form is a comma-separated string, so the policy's list
  // joins into it. Applied at binding time, which is inside the
  // constructor, and on BOTH entry paths - connect/adopt and the
  // declarative build both delegate here. Unlike `base` above, which is
  // a default the caller may override, an allowlist is ENFORCEMENT:
  // policy wins over whatever the options carry, on exactly the keys it
  // sets.
  const pallow = profilePlugin?.policy?.allow
  if (null != pallow && 'object' === typeof pallow) {
    const allow = {
      ...(null != options.allow && 'object' === typeof options.allow
        ? options.allow : {}),
    }
    if (Array.isArray(pallow.op)) { allow.op = pallow.op.join(',') }
    if (Array.isArray(pallow.method)) { allow.method = pallow.method.join(',') }
    options.allow = allow
  }

  if ('none' !== binding.rung) {
    const placeholder = binding.placeholder

    // A real credential already resident in the options is hoisted
    // into the broker and replaced by the placeholder before
    // construction completes (design §3.1 adopt) - options() and
    // prepare() output become placeholder-safe from here on.
    const resident = options.apikey
    if ('string' === typeof resident && '' !== resident && placeholder !== resident) {
      station._hoist(name, resident)
    }
    options.apikey = placeholder
  }

  // Wrap the transport. Copy-on-inject (design §5.3) happens inside
  // station._transport; auth-inactive plugins skip credential
  // planning but the wrap still observes (design §5.3).
  const inner = utility.fetcher
  if (true === inner.__station__) {
    throw new StationError('station_bound_twice',
      'plugin "' + name + '" already carries a station wrap')
  }
  const wrapped = async (fctx, fullurl, fetchdef) => {
    return station._transport(name, inner, fctx, fullurl, fetchdef)
  }
  wrapped.__station__ = true
  utility.fetcher = wrapped

  return {
    // The INSTANCE name (§7.1). Keeps the field name so the generated
    // adapter contract is unchanged; for a single-instance project it
    // is the api slug, exactly as before.
    slug: name,

    // Hook bridge (design §3 item 3): operation semantics correlated
    // with the HTTP events via a per-operation id on the SDK's own ctx.
    PrePoint(opctx) {
      opctx.station$ = { corr: 'c' + (++corrSeq), start: Date.now() }
    },
    PreDone(opctx) {
      station._opEvent(name, opctx, resultOutcome(opctx))
    },
    PreUnexpected(opctx) {
      station._opEvent(name, opctx, 'unexpected')
    },
  }
}

// The carried adapter: the retrofit path for SDKs generated without
// the station feature (design §3.1 adopt). A duck-typed Feature whose
// init/hooks delegate to featureBinding - it exists so connect/adopt
// work on any regenerated SDK, and it must stay behaviorally identical
// to the generated feature template in sdkgen-station.
function adapterFeature(station, calleropts) {
  const feature = {
    name: 'station',
    version: '0.0.1',
    active: true,
    _binding: null,

    // featureAdd reads _options for positioning: immediately after the
    // test feature's base transport (design §3.3). When test is absent
    // from the add order this is a no-op append, which for a bare SDK
    // still lands the wrap immediately outside the base transport.
    _options: { __after__: 'test' },

    init(ctx, fopts) {
      feature._binding = featureBinding(ctx, { ...fopts, station, calleropts })
    },
    PrePoint(ctx) { feature._binding?.PrePoint(ctx) },
    PreDone(ctx) { feature._binding?.PreDone(ctx) },
    PreUnexpected(ctx) { feature._binding?.PreUnexpected(ctx) },
  }
  return feature
}

function resultOutcome(ctx) {
  const result = ctx.result
  if (null == result) { return 'unknown' }
  if (null != result.err) { return 'err' }
  if (false === result.ok) { return 'err' }
  return 'ok'
}

module.exports = {
  adapterFeature,
  featureBinding,
}
