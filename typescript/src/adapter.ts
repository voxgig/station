import { StationError } from './error'
import { placeholderFor } from './secrets'
import type { Station } from './Station'

// The hand-written ts adapter (design §3): the station side of the
// plugin contract, duck-typed to the generated SDK's Feature interface
// so it can ride options.extend into any generated ts SDK. This is the
// library's carried copy - the generated station feature (sdkgen
// package, later) emits an equivalent that calls the same library.
//
// Once the sdkgen feature exists, this file is what it must agree with:
// registration at init, transport wrap immediately outside the base
// transport, hook bridge for op events, placeholder-only credentials.

let corrSeq = 0

export function adapterFeature(station: Station, calleropts: any): any {
  const feature: any = {
    name: 'station',
    version: '0.0.1',
    active: true,

    // featureAdd reads _options for positioning: immediately after the
    // test feature's base transport (design §3.3). When test is absent
    // from the add order this is a no-op append, which for a bare SDK
    // still lands the wrap immediately outside the base transport.
    _options: { __after__: 'test' },

    init(ctx: any, _fopts: any): void {
      const client = ctx.client
      const utility = ctx.utility
      const options = ctx.options

      // Position guard (design §3.3): the wrap must sit immediately
      // outside the base transport - inside retry/cache/ratelimit -
      // or its http events stop being wire truth. Position in
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

      const reg = station._register(client, ctx.config, options, calleropts)
      const { binding, profilePlugin } = reg
      const slug = binding.plugin

      // Base URL precedence (design §3.5): caller opts (7) beat the
      // profile (4), which beats the SDK's config default (1) already
      // in options.base. Spec reads options.base per op, so setting it
      // at init covers every subsequent operation.
      if (null == calleropts?.base && null != profilePlugin?.base) {
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

        // Wrap the transport. Copy-on-inject (design §5.3): fetchdef
        // and its headers are cloned before the swap, so ctrl.explain,
        // ctx.spec and every hook still hold only the placeholder.
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
      }
      else {
        // Auth-inactive SDKs skip credential planning entirely but get
        // everything else (design §5.3) - the wrap still observes.
        const inner = utility.fetcher
        const wrapped = async (fctx: any, fullurl: string, fetchdef: any) => {
          return station._transport(slug, inner, fctx, fullurl, fetchdef)
        }
        ;(wrapped as any).__station__ = true
        utility.fetcher = wrapped
      }

      feature._slug = slug
    },

    // Hook bridge (design §3 item 3): operation semantics correlated
    // with the HTTP events via a per-operation id on the SDK's own ctx.
    PrePoint(ctx: any): void {
      ctx.station$ = {
        corr: 'c' + (++corrSeq),
        start: Date.now(),
      }
    },

    PreDone(ctx: any): void {
      station._opEvent(feature._slug, ctx, resultOutcome(ctx))
    },

    PreUnexpected(ctx: any): void {
      station._opEvent(feature._slug, ctx, 'unexpected')
    },
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
