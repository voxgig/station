// RUN: npm test
//
// Stage 3b (design §8): the three-level merge, the constraint-and-band
// resolver, and the descriptor-derived checker.
//
// The resolver is deliberately the same shape as voxgig/plugin's `order`
// corpus section, because it is the one station holds itself to under
// C4 — a divergence here is a divergence from plugin's §7 semantics,
// which is the thing the joint plan is trying to prevent.

import { describe, test } from 'node:test'
import { deepStrictEqual, equal, throws } from 'node:assert'

import {
  checkfeatures, checkpin, composefeatures, defaultband, featuresources,
  mergefeatures, resolveorder,
} from '../src/feature'

const order = (m: any) => resolveorder(m).map((o) => o.name)

describe('feature-merge', () => {

  test('merges per feature name, then per option key', () => {
    // Composition is the entire point: a fleet default plus a
    // per-instance tweak.
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
    // TWO LEVELS AND NO DEEPER, which is what `{"$MERGE":{"deep":2}}`
    // states and what a port defaulting to a deep merge would silently
    // get wrong.
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

    // PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY: an overlay's
    // PROFILE-level value beats a base profile's INSTANCE-level one.
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
    // `test` substitutes the base transport so it is innermost;
    // `station` sits immediately outside it; everything else is outside
    // station. Two band values rather than two special cases.
    equal(0, defaultband('retry'))
    equal(100, defaultband('station'))
    equal(200, defaultband('test'))

    deepStrictEqual(
      order({ station: {}, retry: {}, test: {}, cache: {} }),
      ['retry', 'cache', 'station', 'test'])
  })

  test('constraints beat bands', () => {
    // Alphabet is not consulted anywhere: `cache` sorts before `retry`
    // but the constraint decides.
    deepStrictEqual(
      order({ retry: {}, cache: { order: { after: 'retry' } } }),
      ['retry', 'cache'])
    deepStrictEqual(
      order({ cache: {}, retry: { order: { before: 'cache' } } }),
      ['retry', 'cache'])
  })

  test('a constraint naming an absent feature is satisfied vacuously', () => {
    // `after: 'test'` loads fine in a project with no test feature -
    // sdkgen's `__after__` behaviour kept rather than reinvented.
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
      { name: 'retry', active: false, options: { retries: 2, statuses: ['500'] } },
      { name: 'log', active: true, options: { level: 'info' } },
    ],
  }

  test('an unknown feature names what the SDK does have', () => {
    const faults = checkfeatures({ nosuch: {} }, descriptor)
    equal(1, faults.length)
    equal('station_feature_unknown', faults[0].code)
    equal(true, -1 !== faults[0].message.indexOf('log, retry'))
  })

  test('an unknown option key is caught — the case that actually bites', () => {
    // `retry.retires: 5` is accepted and silently ignored today:
    // makeOptions' feature spec is `$OPEN` per feature, so the SDK
    // cannot catch it and nothing else looks.
    const faults = checkfeatures({ retry: { retires: 5 } }, descriptor)
    equal(1, faults.length)
    equal('station_feature_option', faults[0].code)
    equal('retires', faults[0].key)
    equal(true, -1 !== faults[0].message.indexOf('retries'))
  })

  test('a scalar option is checked against its default s type', () => {
    const faults = checkfeatures({ retry: { retries: 'three' } }, descriptor)
    equal(1, faults.length)
    equal('station_feature_option', faults[0].code)

    deepStrictEqual(checkfeatures({ retry: { retries: 5 } }, descriptor), [])
  })

  test('compound options are checked to KIND only, and that limit is real', () => {
    // A list default establishes list-ness and nothing about elements.
    deepStrictEqual(
      checkfeatures({ retry: { statuses: [{}, 7] } }, descriptor), [])
    // ...but the kind itself is still checked.
    equal(1, checkfeatures({ retry: { statuses: 'nope' } }, descriptor).length)
  })

  test('the reserved keys are not options', () => {
    deepStrictEqual(
      checkfeatures({ retry: { active: true, order: { band: 1 } } }, descriptor),
      [])
  })
})
