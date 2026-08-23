// RUN: npm test
//
// Stage 3's front door (design §6): the instance table is built at
// `open()`, nothing is constructed there, and `sdk(name)` builds on
// first ask and caches.
//
// §10.2's requirement is an integration test against the real generated
// taskpad SDK and two live servers, and it skips without a checkout.
// This is the half that does NOT need one: the factory table takes a
// `{construct, config}` pair, so a fake factory exercises exactly the
// path a generated package's self-registration takes.

import { after, beforeEach, describe, test } from 'node:test'
import { deepStrictEqual, equal, notEqual, ok, throws } from 'node:assert'

import { Station } from '../src/Station'
import { camelify, checkPackage, factoryFromModule } from '../src/loader'
import { provide, provided, resetFactories } from '../src/factory'

// Enough of a generated SDK for the adapter to bind: the module-level
// `config` singleton §6.2 relies on, and a constructor that activates
// the station feature the way a generated one does.
function fakeSDK(slug: string) {
  const config = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { auth: { prefix: 'Bearer ' }, server: {} },
    entity: {},
  }
  let built = 0
  class SDK {
    options: any
    _features = [{ name: 'station' }]
    _mode = 'test'
    constructor(options: any) {
      this.options = options
      built++
      const fopts = options?.feature?.station
      if (null != fopts) {
        // eslint-disable-next-line @typescript-eslint/no-var-requires
        const { featureBinding } = require('../src/adapter')
        featureBinding({
          client: this,
          utility: { fetcher: async () => ({ status: 200 }) },
          options: { feature: {} },
          config,
        }, fopts)
      }
    }
  }
  return { config, SDK, builtCount: () => built }
}

function station(sdk: Record<string, any>, extra?: any) {
  return new Station({
    config: { station: 1, profiles: { default: { sdk } } },
    ...(extra || {}),
  })
}

describe('declarative-front-door', () => {
  beforeEach(() => resetFactories())
  after(() => resetFactories())

  test('open() constructs nothing; sdk() builds on first ask and caches', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': {} })

    // The instance table exists and NOTHING has been constructed.
    deepStrictEqual(st.instances().map((r) => r.name), ['stripe$test'])
    equal(0, stripe.builtCount())
    equal(0, st.plugins().length)

    const a = st.sdk('stripe$test')
    equal(1, stripe.builtCount())

    // Same name -> same object: the rest are a map lookup, which is
    // what makes "get it where you need it" a real instruction.
    ok(a === st.sdk('stripe$test'))
    equal(1, stripe.builtCount())

    st.close()
  })

  test('two instances of one api, from config alone', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({
      'stripe$test': { base: 'https://test.example' },
      'stripe$live': { base: 'https://live.example' },
    })

    const t = st.sdk('stripe$test')
    const l = st.sdk('stripe$live')

    notEqual(t, l)
    equal(2, stripe.builtCount())
    deepStrictEqual(st.plugins().map((p) => p.name).sort(),
      ['stripe$live', 'stripe$test'])

    // Each carries its own resolved block, and its own derived secret.
    equal('https://test.example', t.options.base)
    equal('https://live.example', l.options.base)
    deepStrictEqual(st.plugins().map((p) => p.secretname).sort(),
      ['stripe_live.apikey', 'stripe_test.apikey'])

    st.close()
  })

  test('create() is uncached and auto-tagged', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': {} })

    const a = st.create('stripe$test')
    const b = st.create('stripe$test')
    notEqual(a, b)

    // A second create() would be station_bound_twice under one name, so
    // each gets the lowest unused positive integer tag - an ORDINARY
    // instance, not a parallel identity scheme.
    deepStrictEqual(st.plugins().map((p) => p.name).sort(),
      ['stripe$1', 'stripe$2'])

    st.close()
  })

  test('availability errors are deferred to first use', () => {
    // §6.4: at 20 SDKs a process that touches three of them must not
    // die because the eighteenth has a typo'd package name.
    const st = station({ 'nofactory$a': {}, 'off$a': { active: false } })

    // open() succeeded despite both being unusable.
    equal(2, st.instances().length)

    throws(() => st.sdk('nofactory$a'), /station_no_factory/)
    throws(() => st.sdk('off$a'), /station_instance_inactive/)
    throws(() => st.sdk('never$a'), /station_no_instance/)

    st.close()
  })

  test('check() turns deferred errors into one visible failure', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({
      'stripe$test': {},
      'nofactory$a': {},
      // Inactive instances are not checked: reaching for a credential
      // belonging to a disabled integration is the wrong default.
      'off$a': { active: false },
    })

    const res = st.check()
    deepStrictEqual(res.ok, ['stripe$test'])
    deepStrictEqual(res.failed.map((f) => f.name), ['nofactory$a'])
    equal('station_no_factory', res.failed[0].code)

    st.close()
  })

  test('a second factory for one api is a conflict, not a silent pick', () => {
    const one = fakeSDK('stripe')
    const two = fakeSDK('stripe')
    const f = { construct: (o: any) => new one.SDK(o), config: one.config }

    provide('stripe', f)
    // Idempotent for the SAME pair: self-registration plus an explicit
    // provide for one api is an ordinary thing to end up with.
    provide('stripe', f)
    deepStrictEqual(provided(), ['stripe'])

    throws(
      () => provide('stripe', { construct: (o: any) => new two.SDK(o), config: two.config }),
      /station_factory_conflict/)
  })

  test('the loader only accepts module names', () => {
    for (const bad of ['./local', '/abs/path', '../up', 'https://x/y', '~/home']) {
      throws(() => checkPackage('stripe', bad), /station_sdk_load/, bad)
    }
    equal('@acme/stripe-sdk', checkPackage('stripe', '@acme/stripe-sdk'))
  })

  test('a user-level `package` is ignored with a warning, not imported', () => {
    const st = new Station({
      config: { station: 1, profiles: { default: { sdk: { 'stripe$a': { package: 'nope' } } } } },
      repoScoped: false,
    })
    const seen: any[] = []
    st.tap((e: any) => seen.push(e))

    // Ignored rather than imported - so the failure is "no factory",
    // never a module loaded from outside the repo's review boundary.
    throws(() => st.sdk('stripe$a'), /station_no_factory/)

    ok(seen.some((e: any) =>
      -1 !== String(e.meta?.warn || '').indexOf('user-level')),
    'a warning event must name why the package was ignored')

    st.close()
  })

  test('load: false disables the loader outright', () => {
    const st = station({ 'stripe$a': { package: 'nope' } }, { load: false })
    throws(() => st.sdk('stripe$a'), /station_no_factory/)
    st.close()
  })

  test('the retrofit path builds a factory from module exports', () => {
    const stripe = fakeSDK('stripe')

    // `export` defaults to the fixed `SDK` alias, which is the same
    // identifier in every generated package.
    const f = factoryFromModule('stripe', { SDK: stripe.SDK, config: stripe.config })
    ok('function' === typeof f.construct)
    equal(stripe.config, f.config)

    // ...then the derived name, then an explicit `export`.
    equal('StripeEu', camelify('stripe-eu'))
    const g = factoryFromModule('stripe-eu',
      { StripeEuSDK: stripe.SDK, config: stripe.config })
    ok('function' === typeof g.construct)

    // A module with a constructor but no config singleton cannot serve
    // §6.2, and says so rather than half-working.
    throws(() => factoryFromModule('stripe', { SDK: stripe.SDK }),
      /station_sdk_load/)
  })
})
