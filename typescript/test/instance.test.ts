
import { describe, test } from 'node:test'
import { deepStrictEqual, equal, notEqual, ok, throws } from 'node:assert'

import { Station } from '../src/Station'
import { featureBinding } from '../src/adapter'
import { instanceRef } from '../src/Station'

// The smallest thing the adapter will bind: a client whose feature list
// puts station immediately outside the base transport (§3.3's position
// guard), and a utility carrying a fetcher for it to wrap.
function fakeClient(slug: string) {
  const client: any = { _features: [{ name: 'station' }], _mode: 'test' }
  const ctx: any = {
    client,
    utility: { fetcher: async () => ({ status: 200 }) },
    options: { feature: {} },
    config: {
      main: { slug, name: slug, version: '1.0.0' },
      options: { auth: { prefix: 'Bearer ' }, server: {} },
      entity: {},
    },
  }
  return { client, ctx }
}

function bind(st: Station, slug: string, fopts: any) {
  const { ctx } = fakeClient(slug)
  return featureBinding(ctx, { station: st, ...fopts })
}

describe('instance-identity', () => {

  test('two instances of one api bind, and are told apart', () => {
    const st = new Station({ config: null })

    const a = bind(st, 'stripe', { as: 'test' })!
    const b = bind(st, 'stripe', { as: 'live' })!

    equal('stripe$test', a.slug)
    equal('stripe$live', b.slug)

    const names = st.plugins().map((p) => p.name).sort()
    deepStrictEqual(names, ['stripe$live', 'stripe$test'])

    deepStrictEqual(st.plugins().map((p) => p.api).sort(),
      ['stripe', 'stripe'])

    st.close()
  })

  test('placeholders and derived secret names follow the instance', () => {
    const st = new Station({ config: null })
    bind(st, 'stripe', { as: 'test' })
    bind(st, 'stripe', { as: 'live' })

    const [live, testi] = st.plugins()
      .sort((x, y) => x.name < y.name ? -1 : 1)

    notEqual(live.name, testi.name)

    equal('stripe_live.apikey', live.secretname)
    equal('stripe_test.apikey', testi.secretname)

    st.close()
  })

  test('the descriptor is shared by every instance of one api', () => {
    const st = new Station({ config: null })
    bind(st, 'stripe', { as: 'test' })
    bind(st, 'stripe', { as: 'live' })

    ok(st.descriptorOf('stripe$test') === st.descriptorOf('stripe$live'),
      'the two instances must share one descriptor object')

    // And the shared object keeps the API-level default rather than
    // either instance's effective name, which is exactly why the
    // effective one had to move to the binding.
    equal('stripe.apikey', st.descriptorOf('stripe$test').auth.secretname)

    st.close()
  })

  test('the single-instance case is unchanged', () => {
    const st = new Station({ config: null })
    const b = bind(st, 'gnarly-pets', {})!

    // A bare connect(SDK) with no name falls back to the descriptor
    // slug, so the ref, the placeholder and the secret name are all
    // byte-identical to what they were before Stage 2.
    equal('gnarly-pets', b.slug)
    equal('gnarly_pets.apikey', st.plugins()[0].secretname)
    equal('gnarly-pets', st.plugins()[0].slug)

    st.close()
  })

  test('binding one instance twice is still an error', () => {
    const st = new Station({ config: null })
    bind(st, 'stripe', { as: 'test' })

    throws(() => bind(st, 'stripe', { as: 'test' }),
      /station_bound_twice/)

    st.close()
  })

  test('`as` is a tag, and a full ref is validated against the api', () => {
    const st = new Station({ config: null })

    equal('stripe$eu', bind(st, 'stripe', { as: 'stripe$eu' })!.slug)

    throws(() => bind(st, 'stripe', { as: 'other$eu' }),
      /station_instance_api/)

    st.close()
  })

  test('instanceRef is pure and total', () => {
    equal('stripe', instanceRef('stripe', {}))
    equal('stripe', instanceRef('stripe', undefined))
    equal('stripe$test', instanceRef('stripe', { as: 'test' }))
    equal('stripe$stripe', instanceRef('stripe', { as: 'stripe' }))
    equal('stripe$eu', instanceRef('stripe', { instance: 'stripe$eu', as: 'x' }))
  })

  test('instances() reports declared instances, live or not', () => {
    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            sdk: {
              'stripe$test': {},
              'stripe$off': { active: false },
            },
          },
        },
      },
    })

    bind(st, 'stripe', { as: 'test' })

    const rows = st.instances()
    deepStrictEqual(rows.map((r) => r.name), ['stripe$off', 'stripe$test'])
    deepStrictEqual(rows.map((r) => r.api), ['stripe', 'stripe'])

    // `active` and `live` answer different questions and the answers
    // differ routinely: a declared-but-unbuilt instance is active and
    // not live, and a barred one is neither.
    deepStrictEqual(rows.map((r) => r.active), [false, true])
    deepStrictEqual(rows.map((r) => r.live), [false, true])

    st.close()
  })


  test('an api block governs an instance the profile never declares', () => {
    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: { api: { stripe: { secret: 'shared.key' } } },
        },
      },
    })

    bind(st, 'stripe', { as: 'test' })

    equal('shared.key', st.plugins()[0].secretname)

    st.close()
  })

  test('the api block s hosts policy reaches an imperative instance', () => {
    // THE ONE THAT MATTERS. A profile whose api block denies egress
    // everywhere denied nothing for a tagged client, because the
    // allowlist was read off a block that did not exist.
    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: { api: { stripe: { policy: { hosts: ['api.stripe.com'] } } } },
        },
      },
    })

    const b = bind(st, 'stripe', { as: 'test' })!
    equal('stripe$test', b.slug)
    deepStrictEqual(
      (st as any).blockFor('stripe$test')?.policy?.hosts, ['api.stripe.com'])

    // ...and a declared instance still wins over its api block, which is
    // the precedence the merge already had and must not lose.
    const st2 = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            api: { stripe: { policy: { hosts: ['api.stripe.com'] } } },
            sdk: { 'stripe$test': { policy: { hosts: ['test.stripe.com'] } } },
          },
        },
      },
    })
    deepStrictEqual(
      (st2 as any).blockFor('stripe$test')?.policy?.hosts, ['test.stripe.com'])

    st.close()
    st2.close()
  })

  test('the transport seam ASKS for the instance s own secret name', async () => {
    const st = new Station({ config: null })
    const asked: string[] = []
    ;(st as any).broker = {
      value: async (_slug: string, name: string) => { asked.push(name); return 'sk' },
      hoist: () => undefined,
      scrub: (t: string) => t,
      refresh: () => undefined,
    }

    const { ctx } = fakeClient('stripe')
    ctx.client._mode = 'live'
    featureBinding(ctx, { station: st, as: 'test' })

    await ctx.utility.fetcher({ client: ctx.client }, 'https://api.stripe.com/v1',
      { headers: {} })

    deepStrictEqual(asked, ['stripe_test.apikey'])

    st.close()
  })

  test('warm() resolves an imperative instance, by its own name', async () => {
    // `warm` read `profile.sdk[name]` and skipped anything absent, so an
    // imperative instance was reported `missed` at startup and its
    // credential was never batched — the one thing the method exists
    // for. It also re-derived the name, dropping the in-code `secret`
    // option that beats the profile (§9).
    const st = new Station({ config: null })
    const asked: string[] = []
    ;(st as any).broker = {
      value: async (_slug: string, name: string) => { asked.push(name); return 'sk' },
      hoist: () => undefined,
      scrub: (t: string) => t,
      refresh: () => undefined,
    }

    bind(st, 'stripe', { as: 'test' })

    const out = await st.warm(['stripe$test'])
    deepStrictEqual(out.warmed, ['stripe$test'])
    deepStrictEqual(out.missed, [])
    deepStrictEqual(asked, ['stripe_test.apikey'])

    st.close()
  })

  test('the registry and the shared descriptor hold different names', () => {
    const st = new Station({ config: null })

    bind(st, 'stripe', { as: 'test' })
    bind(st, 'stripe', { as: 'live' })

    const [live, testi] = st.plugins()
      .sort((x, y) => x.name < y.name ? -1 : 1)

    equal('stripe_live.apikey', live.secretname)
    equal('stripe_test.apikey', testi.secretname)

    equal('stripe.apikey', st.descriptorOf('stripe$test').auth.secretname)
    equal('stripe.apikey', st.descriptorOf('stripe$live').auth.secretname)

    st.close()
  })
})
