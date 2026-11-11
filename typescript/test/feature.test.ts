
import { describe, test } from 'node:test'
import { deepStrictEqual, equal, ok, throws } from 'node:assert'

import {
  checkfeatures, checkpin, composefeatures, defaultband, featuresources,
  mergefeatures, resolveorder,
} from '../src/feature'
import { normalizeDescriptor } from '../src/descriptor'
import { Station } from '../src/Station'

const order = (m: any) => resolveorder(m).map((o) => o.name)

describe('feature-merge', () => {

  test('merges per feature name, then per option key', () => {
    const merged = mergefeatures([
      { retry: { active: true, retries: 3 }, log: { active: true } },
      { retry: { retries: 5 } },
    ])
    deepStrictEqual(merged, {
      retry: { active: true, retries: 5 },
      log: { active: true },
    })
  })

  test('the depth boundary: a map-valued option replaces wholesale', () => {
    const merged = mergefeatures([
      { proxy: { headers: { a: '1', b: '2' } } },
      { proxy: { headers: { c: '3' } } },
    ])
    deepStrictEqual(merged.proxy.headers, { c: '3' })
  })

  test('the six sources are read in §3.3 order', () => {
    const base = {
      feature: { retry: { retries: 1 } },
      api: { stripe: { feature: { retry: { retries: 2 } } } },
      sdk: { 'stripe$t': { feature: { retry: { retries: 3 } } } },
    }
    const overlay = {
      feature: { retry: { retries: 4 } },
      api: { stripe: { feature: { retry: { retries: 5 } } } },
      sdk: { 'stripe$t': { feature: { retry: { retries: 6 } } } },
    }
    const merged = mergefeatures(
      featuresources(base, overlay, 'stripe', 'stripe$t'))
    equal(6, merged.retry.retries)

    const merged2 = mergefeatures(featuresources(
      { sdk: { 'stripe$t': { feature: { retry: { retries: 3 } } } } },
      { feature: { retry: { retries: 4 } } },
      'stripe', 'stripe$t'))
    equal(4, merged2.retry.retries)
  })

  test('a tuning-only entry does not switch a feature back on', () => {
    // The §3.3 defect ONE LEVEL DOWN: a broader level turned `retry`
    // off, and a narrower one mentions only a tuning key. Synthesizing
    // `active` into the narrower entry before merging would re-enable
    // it — silently, and in whichever environment carried the tweak.
    const merged = mergefeatures([
      { retry: { active: false } },
      { retry: { retries: 3 } },
    ])
    equal(false, merged.retry.active)
    deepStrictEqual(order(merged), [])
  })
})

describe('feature-order', () => {

  test('with no constraints written, the default is today s nesting', () => {
    equal(0, defaultband('retry'))
    equal(100, defaultband('station'))
    equal(200, defaultband('test'))

    deepStrictEqual(
      order({ station: {}, retry: {}, test: {}, cache: {} }),
      ['retry', 'cache', 'station', 'test'])
  })

  test('constraints beat bands', () => {
    deepStrictEqual(
      order({ retry: {}, cache: { order: { after: 'retry' } } }),
      ['retry', 'cache'])
    deepStrictEqual(
      order({ cache: {}, retry: { order: { before: 'cache' } } }),
      ['retry', 'cache'])
  })

  test('a constraint naming an absent feature is satisfied vacuously', () => {
    deepStrictEqual(order({ retry: { order: { after: 'test' } } }), ['retry'])
    deepStrictEqual(
      order({ retry: { order: { before: ['nope', 'gone'] } } }), ['retry'])
  })

  test('bands break a tie no constraint decides', () => {
    deepStrictEqual(
      order({ a: { order: { band: 5 } }, b: { order: { band: 1 } } }),
      ['b', 'a'])
  })

  test('remaining ties break by declaration position, not alphabet', () => {
    deepStrictEqual(order({ zeta: {}, alpha: {} }), ['zeta', 'alpha'])
  })

  test('a cycle is station_feature_order', () => {
    throws(() => order({
      a: { order: { after: 'b' } },
      b: { order: { after: 'a' } },
    }), /station_feature_order/)
  })

  test('inactive features are not ordered at all', () => {
    deepStrictEqual(order({ retry: { active: false }, cache: {} }), ['cache'])
  })

  test('station s position is pinned innermost, and moving it is rejected', () => {
    checkpin(resolveorder({ retry: {}, station: {} }))
    checkpin(resolveorder({ retry: {}, station: {}, test: {} }))

    // An order that would put a wrapper between station and the base
    // is refused rather than honoured: position VERIFICATION only tells
    // a binding it was misplaced after the fact, where a pin makes the
    // misplacement inexpressible.
    throws(() => checkpin(resolveorder({
      station: {},
      retry: { order: { after: 'station' } },
    })), /station_feature_order/)
  })

  test('composing drops the reserved keys', () => {
    const composed = composefeatures(resolveorder({
      retry: { active: true, retries: 3, order: { band: 0 } },
    }))
    deepStrictEqual(composed, [{ name: 'retry', active: true, retries: 3 }])
  })
})

describe('feature-check', () => {
  const descriptor = {
    features: [
      {
        name: 'retry', active: false, options: { retries: 2, statuses: ['500'] },
        optspec: { jitter: '`$BOOLEAN`' }, strict: true,
      },
      { name: 'log', active: true, options: { level: 'info' } },
    ],
  }

  test('an unknown feature names what the SDK does have', () => {
    const faults = checkfeatures({ nosuch: {} }, descriptor)
    equal(1, faults.length)
    equal('station_feature_unknown', faults[0].code)
    equal(true, -1 !== faults[0].message.indexOf('log, retry'))
  })

  test('an unknown option key is caught when the feature is strict', () => {
    const faults = checkfeatures({ retry: { retires: 5 } }, descriptor)
    equal(1, faults.length)
    equal('station_feature_option', faults[0].code)
    equal('retires', faults[0].key)
    equal(true,
      -1 !== faults[0].message.indexOf('[jitter, retries, statuses]'))
  })

  test('a feature that is not strict accepts what its SDK accepts', () => {
    // sdkgen opens a feature's option spec unless `strict` is true, and
    // `strict` defaults to false, so absent and false are one case.
    deepStrictEqual(checkfeatures({ log: { lvel: 'debug' } }, descriptor), [])
    deepStrictEqual(checkfeatures({ log: { level: 7 } }, descriptor).length, 1)
  })

  test('an optspec key is declared, and checked against its type', () => {
    // The `test` feature as sdkgen emits it: its seed options carry a
    // type and no default.
    const testfeature = {
      features: [{
        name: 'test', active: false, options: { active: false },
        optspec: { entity: '`$MAP`', net: '`$MAP`' }, strict: false,
      }],
    }
    deepStrictEqual(checkfeatures(
      { test: { active: true, entity: { note: {} }, net: { offline: true } } },
      testfeature), [])

    const faults = checkfeatures({ test: { net: 'offline' } }, testfeature)
    equal(1, faults.length)
    equal('net', faults[0].key)
    equal(true, -1 !== faults[0].message.indexOf('expects map, but found string'))

    deepStrictEqual(checkfeatures({ retry: { jitter: true } }, descriptor), [])
    equal(1, checkfeatures({ retry: { jitter: 'yes' } }, descriptor).length)
  })

  test('an optspec type outranks the default it sits beside', () => {
    const netsim = {
      features: [{
        name: 'netsim', active: false, options: { active: false, latency: 0 },
        optspec: { latency: ['`$ONE`', '`$NUMBER`', '`$MAP`'] },
      }],
    }
    deepStrictEqual(
      checkfeatures({ netsim: { latency: { min: 10, max: 50 } } }, netsim), [])
    deepStrictEqual(checkfeatures({ netsim: { latency: 20 } }, netsim), [])
    equal(true, -1 !== checkfeatures({ netsim: { latency: 'slow' } }, netsim)[0]
      .message.indexOf('expects number or map'))
  })

  test('a scalar option is checked against its default s type', () => {
    const faults = checkfeatures({ retry: { retries: 'three' } }, descriptor)
    equal(1, faults.length)
    equal('station_feature_option', faults[0].code)

    deepStrictEqual(checkfeatures({ retry: { retries: 5 } }, descriptor), [])
  })

  test('compound options are checked to KIND only, and that limit is real', () => {
    deepStrictEqual(
      checkfeatures({ retry: { statuses: [{}, 7] } }, descriptor), [])
    equal(1, checkfeatures({ retry: { statuses: 'nope' } }, descriptor).length)
  })

  test('the reserved keys are not options', () => {
    deepStrictEqual(
      checkfeatures({ retry: { active: true, order: { band: 1 } } }, descriptor),
      [])
  })
})

// Stage 4's half that is checkable here: sdkgen-station's feature model
// declares `transport` and the `instance` option, and station's own
// descriptor and checker are what read them. The model file is data, so
// what it declares can be asserted against the code that consumes it
// without generating an SDK.
describe('feature-model-contract', () => {
  const stationFeature = {
    transport: 'wrap',
    options: {
      active: false, url: '', fromEnv: true, profile: '', secret: '',
      instance: '', register: true, capture: 'meta',
    },
  }

  test('the descriptor carries the declared role and option list', () => {
    const { descriptor } = normalizeDescriptor(
      {
        main: { slug: 'pad', name: 'pad', version: '1.0.0' },
        options: { auth: { prefix: 'B ' }, server: {} },
        entity: {},
        feature: { station: stationFeature },
      },
      { station: { active: true } })

    const f = descriptor.features.find((x: any) => 'station' === x.name)!
    // §8.4: the role cannot be inferred - the obvious signal, an empty
    // `hook: {}`, is wrong for exactly this feature. It is carried.
    equal('wrap', f.transport)
    equal('', f.options!.instance)
  })

  test('§7.5 s `instance` option is not reported unknown', () => {
    const { descriptor } = normalizeDescriptor(
      {
        main: { slug: 'pad', name: 'pad', version: '1.0.0' },
        options: { auth: { prefix: 'B ' }, server: {} },
        entity: {},
        feature: { station: stationFeature },
      },
      { station: { active: true } })

    // Station puts the instance name here before construction, and the
    // model declares it, so even a strict reading accepts it.
    deepStrictEqual(
      checkfeatures({ station: { instance: 'pad$eu' } }, descriptor), [])

    const strict = {
      features: descriptor.features.map((f: any) => ({ ...f, strict: true })),
    }
    deepStrictEqual(
      checkfeatures({ station: { instance: 'pad$eu' } }, strict), [])
    equal('station_feature_option',
      checkfeatures({ station: { instanse: 'pad$eu' } }, strict)[0].code)
  })
})


describe('the pin check sees the implicit station entry', () => {

  test('a constraint against `station` is REJECTED, not vacuous', () => {
    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            sdk: {
              'stripe$a': {
                feature: { retry: { order: { after: 'station' } } },
              },
            },
          },
        },
      },
    })

    throws(() => st.featuresOf('stripe$a'), /station_feature_order/)
    st.close()
  })

  test('...and the reported order names it', () => {
    // The other half: an order that omits the feature whose position is
    // pinned cannot be read to check that position.
    const st = new Station({
      config: {
        station: 1,
        profiles: { default: { sdk: { 'stripe$a': { feature: { retry: {} } } } } },
      },
    })

    const { ordered } = st.featuresOf('stripe$a')
    ok(-1 !== ordered.indexOf('station'), 'station is part of the wrap order')
    equal('station', ordered[ordered.length - 1])
    st.close()
  })
})
