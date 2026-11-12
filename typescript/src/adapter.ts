import { StationError } from './error'
import { Station } from './Station'


let corrSeq = 0

export type FeatureBinding = {
  slug: string
  PrePoint(ctx: any): void
  PreDone(ctx: any): void
  PreUnexpected(ctx: any): void
}

export function featureBinding(ctx: any, fopts: any): FeatureBinding | null {
  const station: Station | null = stationOf(fopts?.station) ?? Station.current()
  if (null == station) { return null }

  const client = ctx.client

  if (null != station._boundEntry(client)) { return null }
  const utility = ctx.utility
  const options = ctx.options
  const calleropts = fopts?.calleropts

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
  const name = binding.plugin

  // Base URL precedence (design §3.5): caller opts (7) beat the
  // profile (4), which beats the SDK's config default (1) already in
  // options.base. Applied only on the connect/adopt path, where the
  // caller opts are knowable; station.options() applies the profile
  // base at options-build time instead.
  if (null != calleropts && null == calleropts.base && null != profilePlugin?.base) {
    options.base = profilePlugin.base
  }

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
    const placeholder = binding.placeholder!

    const resident = options.apikey
    if ('string' === typeof resident && '' !== resident && placeholder !== resident) {
      station._hoist(name, resident)
    }
    options.apikey = placeholder
  }

  const inner = utility.fetcher
  if (true === (inner as any).__station__) {
    throw new StationError('station_bound_twice',
      'plugin "' + name + '" already carries a station wrap')
  }
  const wrapped = async (fctx: any, fullurl: string, fetchdef: any) => {
    return station._transport(name, inner, fctx, fullurl, fetchdef)
  }
  ;(wrapped as any).__station__ = true
  utility.fetcher = wrapped

  return {
    slug: name,

    PrePoint(opctx: any): void {
      opctx.station$ = { corr: 'c' + (++corrSeq), start: Date.now() }
    },
    PreDone(opctx: any): void {
      station._opEvent(name, opctx, resultOutcome(opctx))
    },
    PreUnexpected(opctx: any): void {
      station._opEvent(name, opctx, 'unexpected')
    },
  }
}

// The activation entry carries a closure; the carried adapter, the Station.
function stationOf(handle: any): Station | null {
  const got = 'function' === typeof handle ? handle() : handle
  return got instanceof Station ? got : null
}

// The carried adapter: the retrofit path for SDKs generated without the
// station feature (design §3.1 adopt). Its init and hooks delegate to
// featureBinding, so it must stay behaviorally identical to the
// generated feature template in sdkgen-station.
export function adapterFeature(station: Station, calleropts: any): any {
  const feature: any = {
    name: 'station',
    version: '0.0.1',
    active: true,
    _binding: null as FeatureBinding | null,

    _options: adapterAnchor(calleropts?.feature),

    init(ctx: any, fopts: any): void {
      feature._binding = featureBinding(ctx, { ...fopts, station, calleropts })
    },
    PrePoint(ctx: any): void { feature._binding?.PrePoint(ctx) },
    PreDone(ctx: any): void { feature._binding?.PreDone(ctx) },
    PreUnexpected(ctx: any): void { feature._binding?.PreUnexpected(ctx) },
  }
  return feature
}

// The generated constructor adds the active features, test first and the
// rest by name, and only then this adapter, at its anchor or else last.
export function adapterAnchor(fmap: any): { [k: string]: string } {
  const names = null == fmap || 'object' !== typeof fmap || Array.isArray(fmap) ? []
    : Object.keys(fmap).filter((n) => 'station' !== n && fmap[n]?.active).sort()
  if (names.includes('test')) { return { __after__: 'test' } }
  return 0 === names.length ? {} : { __before__: names[0] }
}

function resultOutcome(ctx: any): string {
  const result = ctx.result
  if (null == result) { return 'unknown' }
  if (null != result.err) { return 'err' }
  if (false === result.ok) { return 'err' }
  return 'ok'
}
