// RUN: npm test
//
// Stage 2's identity change (design §7): the registry is keyed by
// INSTANCE, not by api slug. These drive `featureBinding` against a
// minimal fake client rather than a generated SDK, because the property
// under test is station's own — two instances of one api, told apart at
// the placeholder, the secret name and the registry — and it must be
// checkable without a generated checkout on disk.

import { describe, test } from 'node:test'
import { deepStrictEqual, equal, notEqual, ok, throws } from 'node:assert'

import { Station } from '../src/Station'
import { featureBinding } from '../src/adapter'
import { instanceRef } from '../src/Station'

// The smallest thing the adapter will bind: a client whose feature list
// puts station immediately outside the base transport (§3.3's position
// guard), and a utility carrying a fetcher for it to wrap.
function fakeClient(slug: string) {
  // `_features` carries feature OBJECTS and their position is init
  // order, which is what the §3.3 wrap-position guard reads.
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

    // §7.1: the registry key is the instance, so two clients of one api
    // is the NORMAL case now.
    equal('stripe$test', a.slug)
    equal('stripe$live', b.slug)

    const names = st.plugins().map((p) => p.name).sort()
    deepStrictEqual(names, ['stripe$live', 'stripe$test'])

    // ...and both report the same api, which is what makes grouping
    // possible at 26 instances over 20 apis.
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

    // §7.2: two live instances of one api MUST have distinct
    // placeholders or the injection seam cannot tell which credential a
    // header wants.
    notEqual(live.name, testi.name)

    // §5.1: names are per instance, and derive through envtoken -
    // `stripe$test` -> `stripe_test.apikey` -> STRIPE_TEST_APIKEY.
    equal('stripe_live.apikey', live.secretname)
    equal('stripe_test.apikey', testi.secretname)

    st.close()
  })

  test('the descriptor is shared by every instance of one api', () => {
    const st = new Station({ config: null })
    bind(st, 'stripe', { as: 'test' })
    bind(st, 'stripe', { as: 'live' })

    // §7.4: normalizeDescriptor runs ONCE per api and every instance
    // holds a reference to the same object - at 26 instances over 20
    // apis that is 20 normalizations, not 26.
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

    // Two clients of one api is the normal case; two bindings of one
    // INSTANCE is still the error it was.
    throws(() => bind(st, 'stripe', { as: 'test' }),
      /station_bound_twice/)

    st.close()
  })

  test('`as` is a tag, and a full ref is validated against the api', () => {
    const st = new Station({ config: null })

    equal('stripe$eu', bind(st, 'stripe', { as: 'stripe$eu' })!.slug)

    // An `as` that took an arbitrary name would reintroduce the
    // second-identity problem the ref re-key removed.
    throws(() => bind(st, 'stripe', { as: 'other$eu' }),
      /station_instance_api/)

    st.close()
  })

  test('instanceRef is pure and total', () => {
    equal('stripe', instanceRef('stripe', {}))
    equal('stripe', instanceRef('stripe', undefined))
    equal('stripe$test', instanceRef('stripe', { as: 'test' }))
    // No special case when the tag happens to equal the api: a rule
    // with no exceptions is the one that ports the same way 20 times.
    equal('stripe$stripe', instanceRef('stripe', { as: 'stripe' }))
    // The declarative path wins over the imperative one.
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
})
