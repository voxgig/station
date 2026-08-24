// RUN: npm test
//
// The §16 solo-expressible policy keys, wired:
//
//  - `mode` gates the operation path in the library: `live` is the
//    default, `block` is the kill switch (refused like the hosts
//    policy), and the proxy-era modes (record|replay|mock) fail
//    `station_no_proxy` until a proxy is attached - accepted grammar,
//    honest refusal.
//  - `allow.op` / `allow.method` are set into the SDK's OWN
//    `options.allow` at binding time, so enforcement rides the SDK's
//    own pipeline (point_op_allow / spec_method_allow).
//  - `budget` composes into the `ratelimit` feature entry of the merged
//    feature map, so ordering and the station pin hold, §8.5 validates
//    it against the SDK's declaration, and the fleet view reports it
//    with `policy.budget` provenance.

import { after, beforeEach, describe, test } from 'node:test'
import { deepStrictEqual, equal, match, ok, throws } from 'node:assert'

import { Station } from '../src/Station'
import { featureBinding } from '../src/adapter'
import { provide, resetFactories } from '../src/factory'

// The instance.test.ts fake client: enough for the adapter to bind,
// with the ctx held so the wrapped fetcher and the live options map are
// both reachable.
function fakeClient(slug: string) {
  const client: any = { _features: [{ name: 'station' }], _mode: 'test' }
  const ctx: any = {
    client,
    utility: { fetcher: async () => ({ status: 200 }) },
    options: { feature: {} },
    config: {
      // Auth-less deliberately (rung 'none'): these tests exercise the
      // policy gates at the transport seam, not credential injection,
      // and an R1 client would reach for a secret on the live path.
      main: { slug, name: slug, version: '1.0.0' },
      options: { server: {} },
      entity: {},
    },
  }
  return { client, ctx }
}

function policyStation(slug: string, policy: any, feature?: any): Station {
  return new Station({
    config: {
      station: 1,
      profiles: {
        default: {
          sdk: { [slug]: { policy, ...(null == feature ? {} : { feature }) } },
        },
      },
    },
  })
}

// Bind, force live mode, and run one request through the wrap.
async function liveRequest(st: Station, slug: string): Promise<any> {
  const { ctx } = fakeClient(slug)
  ctx.client._mode = 'live'
  featureBinding(ctx, { station: st })
  return ctx.utility.fetcher({ client: ctx.client }, 'https://api.x.com/v1',
    { headers: {} })
}

describe('policy-mode', () => {

  test('mode "block" refuses a live operation, like the hosts policy', async () => {
    // §16: "`block` is the kill switch". §14 names no mode-specific
    // code, so this raises station_host_allow - the closest existing
    // catalog code: the same `_allow` gate grammar at the same seam,
    // egress denied by this plugin's policy - with the mode in the
    // message. No new code is invented.
    const st = policyStation('solar', { mode: 'block' })
    const out = await liveRequest(st, 'solar')

    ok(out instanceof Error)
    equal('station_host_allow', (out as any).code)
    match(String((out as any).message), /mode "block"/)

    // ...and the refusal is an error EVENT too, like every operation
    // failure at this seam.
    const errs = st.events().filter((e) => 'error' === e.kind)
    equal(1, errs.length)
    equal('station_host_allow', errs[0].err!.code)
    st.close()
  })

  test('proxy-era modes are accepted grammar that fails station_no_proxy', async () => {
    // record|replay|mock are §16 vocabulary a proxy-era config already
    // writes. Solo accepts the config (not a validation error) and the
    // operation path fails closed exactly as `require` does - the
    // proxy-shaped behavior cannot be delivered, and pretending
    // otherwise would be worse.
    for (const mode of ['record', 'replay', 'mock']) {
      const st = policyStation('solar', { mode })
      const out = await liveRequest(st, 'solar')
      ok(out instanceof Error, mode + ' must refuse')
      equal('station_no_proxy', (out as any).code)
      st.close()
    }
  })

  test('mode "live" and an absent mode both pass traffic', async () => {
    for (const policy of [{ mode: 'live' }, {}]) {
      const st = policyStation('solar', policy)
      const out = await liveRequest(st, 'solar')
      equal(200, out.status)
      st.close()
    }
  })

  test('mode gates LIVE traffic only, like hosts', async () => {
    // A test-mode client's mock transport is not egress; the §16 kill
    // switch stops requests leaving the process, and in test mode none
    // do.
    const st = policyStation('solar', { mode: 'block' })
    const { ctx } = fakeClient('solar')
    featureBinding(ctx, { station: st })
    const out = await ctx.utility.fetcher({ client: ctx.client },
      'https://api.x.com/v1', { headers: {} })
    equal(200, out.status)
    st.close()
  })
})

describe('policy-allow', () => {

  test('allow.op and allow.method reach the SDK s own options.allow', () => {
    // §16: "the same vocabulary the SDKs already enforce
    // (`options.allow` ...); station sets these SDK options from policy
    // so enforcement is in the SDK's own pipeline". The SDK's option
    // form is the comma-separated string its own default uses.
    const st = policyStation('solar',
      { allow: { op: ['load', 'list'], method: ['GET'] } })

    const { ctx } = fakeClient('solar')
    featureBinding(ctx, { station: st })

    equal('load,list', ctx.options.allow.op)
    equal('GET', ctx.options.allow.method)
    st.close()
  })

  test('policy sets only the keys it carries, and wins over caller opts', () => {
    // Unlike `base` (a default the caller may override), an allowlist
    // is ENFORCEMENT: the policy value wins on the key it sets, and the
    // caller's other allow keys survive beside it.
    const st = policyStation('solar', { allow: { op: ['load'] } })

    const { ctx } = fakeClient('solar')
    ctx.options.allow = { op: 'create,load,list', method: 'GET,POST' }
    featureBinding(ctx, { station: st })

    equal('load', ctx.options.allow.op)
    equal('GET,POST', ctx.options.allow.method)
    st.close()
  })

  test('an api-level allow reaches a tagged instance', () => {
    // blockFor's one-rule-one-place: the api block governs an instance
    // the profile never declares, for allow exactly as it does for
    // hosts.
    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: { api: { solar: { policy: { allow: { method: ['GET'] } } } } },
        },
      },
    })
    const { ctx } = fakeClient('solar')
    featureBinding(ctx, { station: st, as: 'eu' })
    equal('GET', ctx.options.allow.method)
    st.close()
  })
})

describe('policy-budget', () => {
  beforeEach(() => resetFactories())
  after(() => resetFactories())

  // A fake generated SDK whose config DECLARES the ratelimit feature
  // with its option schema, the way a generated one does - §8.5's
  // checker validates the budget-composed entry against exactly this.
  function fakeSDK(slug: string) {
    const config: any = {
      main: { slug, name: slug, version: '1.0.0' },
      options: { auth: { prefix: 'Bearer ' }, server: {} },
      entity: {},
      feature: { ratelimit: { options: { rate: 5, burst: 5 } } },
    }
    class SDK {
      options: any
      _features = [{ name: 'station' }]
      _mode = 'test'
      constructor(options: any) {
        this.options = options
        const fopts = options?.feature?.station
        if (null != fopts) {
          featureBinding({
            client: this,
            utility: { fetcher: async () => ({ status: 200 }) },
            options: { feature: {} },
            config,
          }, fopts)
        }
      }
    }
    return { config, SDK }
  }

  test('budget reaches the ratelimit feature map at construction', () => {
    // §16: "`budget:` rps/concurrency ceilings (the SDK `ratelimit`
    // feature, configured by station ...)". rps is the token bucket's
    // refill rate (same unit, per second); concurrency its capacity
    // (`burst`) - how many requests can be in flight from a full
    // bucket.
    const solar = fakeSDK('solar')
    provide('solar', { construct: (o: any) => new solar.SDK(o), config: solar.config })

    const st = policyStation('solar', { budget: { rps: 3, concurrency: 2 } })
    const client: any = st.sdk('solar')

    deepStrictEqual(client.options.feature.ratelimit,
      { active: true, rate: 3, burst: 2 })
    st.close()
  })

  test('budget composes OVER a config feature entry; other keys survive', () => {
    // Policy is enforcement, not a default: it wins on the keys it
    // sets, while the feature entry's own tuning rides along.
    const solar = fakeSDK('solar')
    provide('solar', { construct: (o: any) => new solar.SDK(o), config: solar.config })

    const st = policyStation('solar', { budget: { rps: 3 } },
      { ratelimit: { rate: 10, burst: 7 } })
    const client: any = st.sdk('solar')

    deepStrictEqual(client.options.feature.ratelimit,
      { active: true, rate: 3, burst: 7 })
    st.close()
  })

  test('the fleet view reports the budget, with policy.budget provenance', () => {
    // §8.7: a merged map alone cannot answer "why is ratelimit on
    // here". The budget rides featuresOf, so features({feature:
    // 'ratelimit'}) answers truthfully and names the level that set it.
    const solar = fakeSDK('solar')
    provide('solar', { construct: (o: any) => new solar.SDK(o), config: solar.config })

    const st = policyStation('solar', { budget: { rps: 3, concurrency: 2 } })
    const { merged, from } = st.featuresOf('solar')

    deepStrictEqual(merged.ratelimit, { active: true, rate: 3, burst: 2 })
    deepStrictEqual(from.ratelimit,
      { active: 'policy.budget', rate: 'policy.budget', burst: 'policy.budget' })
    st.close()
  })

  test('a budget on an SDK with no ratelimit feature is an error, not a no-op', () => {
    // The worst outcome for a policy file is a ceiling that quietly
    // does nothing (§8.5's whole argument). The budget-composed entry
    // goes through the same descriptor-derived check as every feature.
    const config: any = {
      main: { slug: 'bare', name: 'bare', version: '1.0.0' },
      options: { auth: { prefix: 'Bearer ' }, server: {} },
      entity: {},
    }
    class SDK { constructor(public options: any) { } }
    provide('bare', { construct: (o: any) => new SDK(o), config })

    const st = policyStation('bare', { budget: { rps: 3 } })
    throws(() => st.sdk('bare'), /station_feature_unknown/)
    st.close()
  })
})
