import { StationError } from './error'
import { Station } from './Station'

// The station side of the plugin contract (design §3), in ONE place:
// featureBinding() is what both entry paths delegate to -
//  - the GENERATED station feature (sdkgen-station's ts template) calls
//    it from its init() and forwards its hook methods;
//  - the library's carried adapter (adapterFeature, the adopt/connect
//    retrofit for SDKs generated without the feature) is a thin shell
//    over the same call.
// Registration at init, wrap position verified, transport wrapped with
// copy-on-inject, hooks bridged to op events. Anything changed here
// changes both paths - which is the point.

let corrSeq = 0

export type FeatureBinding = {
  slug: string
  PrePoint(ctx: any): void
  PreDone(ctx: any): void
  PreUnexpected(ctx: any): void
}

// Resolve the station this activation binds to: an explicit handle in
// the feature options (connect/adopt and st.options() pass one), else
// the ambient instance. No station open -> null: an activated feature
// with no opened station is an inert no-op that emits nothing and
// fails nothing (design §3.1).
export function featureBinding(ctx: any, fopts: any): FeatureBinding | null {
  const station: Station | null =
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
  const names = client._features.map((f: any) => f.name)
  const self = names.indexOf('station')
  const testAt = names.indexOf('test')
  const expected = -1 === testAt ? 0 : testAt + 1
  if (self !== expected) {
    throw new StationError('station_wrap_order',
      'station must init immediately after the base transport; ' +
      'feature order is [' + names.join(', ') + ']')
  }

  const reg = station._register(client, ctx.config, options, calleropts, fopts)
  const { binding, profilePlugin } = reg
  const slug = binding.plugin

  // Base URL precedence (design §3.5): caller opts (7) beat the
  // profile (4), which beats the SDK's config default (1) already in
  // options.base. Applied only on the connect/adopt path, where the
  // caller opts are knowable; station.options() applies the profile
  // base at options-build time instead.
  if (null != calleropts && null == calleropts.base && null != profilePlugin?.base) {
    options.base = profilePlugin.base
  }

  if ('none' !== binding.rung) {
    const placeholder = binding.placeholder!

    // A real credential already resident in the options is hoisted
    // into the broker and replaced by the placeholder before
    // construction completes (design §3.1 adopt) - options() and
    // prepare() output become placeholder-safe from here on.
    const resident = options.apikey
    if ('string' === typeof resident && '' !== resident && placeholder !== resident) {
      station._hoist(slug, resident)
    }
    options.apikey = placeholder
  }

  // Wrap the transport. Copy-on-inject (design §5.3) happens inside
  // station._transport; auth-inactive plugins skip credential
  // planning but the wrap still observes (design §5.3).
  const inner = utility.fetcher
  if (true === (inner as any).__station__) {
    throw new StationError('station_bound_twice',
      'plugin "' + slug + '" already carries a station wrap')
  }
  const wrapped = async (fctx: any, fullurl: string, fetchdef: any) => {
    return station._transport(slug, inner, fctx, fullurl, fetchdef)
  }
  ;(wrapped as any).__station__ = true
  utility.fetcher = wrapped

  return {
    slug,

    // Hook bridge (design §3 item 3): operation semantics correlated
    // with the HTTP events via a per-operation id on the SDK's own ctx.
    PrePoint(opctx: any): void {
      opctx.station$ = { corr: 'c' + (++corrSeq), start: Date.now() }
    },
    PreDone(opctx: any): void {
      station._opEvent(slug, opctx, resultOutcome(opctx))
    },
    PreUnexpected(opctx: any): void {
      station._opEvent(slug, opctx, 'unexpected')
    },
  }
}

// The carried adapter: the retrofit path for SDKs generated without
// the station feature (design §3.1 adopt). A duck-typed Feature whose
// init/hooks delegate to featureBinding - it exists so connect/adopt
// work on any regenerated SDK, and it must stay behaviorally identical
// to the generated feature template in sdkgen-station.
export function adapterFeature(station: Station, calleropts: any): any {
  const feature: any = {
    name: 'station',
    version: '0.0.1',
    active: true,
    _binding: null as FeatureBinding | null,

    // featureAdd reads _options for positioning: immediately after the
    // test feature's base transport (design §3.3). When test is absent
    // from the add order this is a no-op append, which for a bare SDK
    // still lands the wrap immediately outside the base transport.
    _options: { __after__: 'test' },

    init(ctx: any, fopts: any): void {
      feature._binding = featureBinding(ctx, { ...fopts, station, calleropts })
    },
    PrePoint(ctx: any): void { feature._binding?.PrePoint(ctx) },
    PreDone(ctx: any): void { feature._binding?.PreDone(ctx) },
    PreUnexpected(ctx: any): void { feature._binding?.PreUnexpected(ctx) },
  }
  return feature
}

function resultOutcome(ctx: any): string {
  const result = ctx.result
  if (null == result) { return 'unknown' }
  if (null != result.err) { return 'err' }
  if (false === result.ok) { return 'err' }
  return 'ok'
}
