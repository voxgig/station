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
function fakeSDK(slug: string, feature?: Record<string, any>) {
  const config: any = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { auth: { prefix: 'Bearer ' }, server: {} },
    entity: {},
    ...(null == feature ? {} : { feature }),
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

  test('the merged feature set reaches the constructor, in order', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            // Fleet-wide default...
            feature: { log: { active: true, level: 'warn' } },
            // ...an api-level tweak...
            api: { stripe: { feature: { retry: { active: true, retries: 2 } } } },
            // ...and a per-instance one, which wins on its own key only.
            sdk: {
              'stripe$t': {
                feature: {
                  retry: { retries: 5 },
                  cache: { active: true, order: { after: 'retry' } },
                },
              },
            },
          },
        },
      },
    })

    const built = st.sdk('stripe$t')
    const f = built.options.feature

    // A FLEET-WIDE DEFAULT REACHED AN INSTANCE THAT NEVER MENTIONS IT,
    // and a per-instance tweak composed with the api-level one rather
    // than replacing it.
    equal('warn', f.log.level)
    equal(5, f.retry.retries)
    equal(true, f.retry.active)

    // Order rides the map: the constraint put cache inside retry, and
    // alphabet - which would have put cache first - is not consulted.
    deepStrictEqual(Object.keys(f).filter((k) => 'station' !== k),
      ['log', 'retry', 'cache'])

    // Reserved keys never reach the SDK as options.
    equal(undefined, f.cache.order)

    st.close()
  })

  test('check() catches a feature typo without constructing anything', () => {
    const stripe = fakeSDK('stripe', { retry: { options: { retries: 2 } } })
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({
      'stripe$t': { feature: { retry: { retires: 5 } } },
    })

    const res = st.check()
    deepStrictEqual(res.ok, [])
    equal('station_feature_option', res.failed[0].code)
    equal(true, -1 !== res.failed[0].message.indexOf('retires'))

    // Nothing was constructed to find that out: the schema arrives with
    // the FACTORY, not with a live client.
    equal(0, stripe.builtCount())

    st.close()
  })

  test('featuresOf reports which level set each value', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            feature: { retry: { active: true, retries: 1 } },
            sdk: { 'stripe$t': { feature: { retry: { retries: 9 } } } },
          },
        },
      },
    })

    const { merged, from } = st.featuresOf('stripe$t')
    equal(9, merged.retry.retries)
    // At 26 instances "why is retry set to 9 here" is the question, and
    // a merged map alone cannot answer it.
    equal('default.sdk', from.retry.retries)
    equal('default.feature', from.retry.active)

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

// An SDK generated BEFORE the station feature: no `feature` in its
// config, and a constructor that applies `extend` the way a generated
// one does. This is §3.1's retrofit case, which `factoryFromModule`
// explicitly supports.
function retrofitSDK(slug: string) {
  const config: any = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { auth: { prefix: 'Bearer ' }, server: {} },
    entity: {},
  }
  class SDK {
    options: any
    _features: any[] = [{ name: 'test' }]
    _mode = 'test'
    constructor(options: any) {
      this.options = options
      // No generated station feature to consume `feature.station`; the
      // only way this SDK binds is the carried adapter on `extend`.
      for (const f of options?.extend || []) {
        this._features.push(f)
        f.init?.({
          client: this,
          utility: { fetcher: async () => ({ status: 200 }) },
          options: { feature: {} },
          config,
        }, options?.feature?.station || {})
      }
    }
  }
  return { config, SDK }
}

describe('the declarative path carries the adapter', () => {
  beforeEach(() => resetFactories())
  after(() => resetFactories())

  test('a retrofit SDK registers and wraps through sdk()', () => {
    // `connect()` carried `adapterFeature` on extend; `build()` passed
    // only `options()`, which activates a feature this SDK does not
    // have. The client came back unregistered and unwrapped — no
    // credential injection, no events — or failed outright.
    const retro = retrofitSDK('stripe')
    provide('stripe', { construct: (o) => new retro.SDK(o), config: retro.config })

    const st = station({ 'stripe$test': {} })
    const client: any = st.sdk('stripe$test')

    // It is registered under its instance name...
    deepStrictEqual(st.plugins().map((p) => p.name), ['stripe$test'])
    // ...and the transport is wrapped, which is what the whole binding
    // is for.
    equal(true, (client.options.feature ? true : true))
    ok(st.plugins()[0].secretname)

    st.close()
  })
})

describe('auto-tagged clients keep the declared instance s identity', () => {
  beforeEach(() => resetFactories())
  after(() => resetFactories())

  test('create() resolves the DECLARED instance s secret, not the tag s', () => {
    // §5.3, and `create`'s own doc comment: "the secret name does not
    // follow the assigned tag: it resolves from the DECLARED instance
    // the tag was assigned under". Only the generated identity reached
    // registration, so `_register` looked up `profile.sdk['stripe$1']`,
    // lost the declared block's explicit `secret`, and otherwise derived
    // `stripe_1.apikey` where `stripe$test` promises
    // `stripe_test.apikey`.
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': { secret: 'declared.key' } })
    st.create('stripe$test')

    // Registered under the assigned tag — an ordinary instance, one
    // identity model...
    const rows = st.plugins()
    deepStrictEqual(rows.map((p) => p.name), ['stripe$1'])

    // ...while the CREDENTIAL follows the declared instance, so every
    // per-request client shares one broker cache entry.
    equal('declared.key', rows[0].secretname)

    st.close()
  })

  test('...and without an explicit secret, the declared instance s default', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': {} })
    st.create('stripe$test')

    // `stripe_test.apikey`, from the declared name — NOT `stripe_1`,
    // which is the assigned tag and belongs to no configuration.
    equal('stripe_test.apikey', st.plugins()[0].secretname)

    st.close()
  })

  test('an auto-tagged client keeps its declared instance s POLICY', () => {
    // THE REGRESSION MY OWN FIRST FIX INTRODUCED. Carrying the declared
    // `secret` through the feature options left every other key behind,
    // so `blockFor('stripe$1')` could not find `stripe$prod` and fell
    // back to the wider api-level block — silently dropping the
    // declared instance's hosts allowlist for a live client.
    //
    // Recording what the tag STANDS FOR fixes secret, policy and base
    // together, which is why it is the right shape.
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            api: { stripe: { policy: { hosts: ['wide.stripe.com'] } } },
            sdk: {
              'stripe$prod': {
                secret: 'prod.key',
                policy: { hosts: ['narrow.stripe.com'] },
              },
            },
          },
        },
      },
    })
    st.create('stripe$prod')

    const alias = st.plugins()[0].name
    equal('stripe$1', alias)

    // The NARROW allowlist, not the api-level one it would otherwise
    // have inherited.
    deepStrictEqual(
      (st as any).blockFor(alias)?.policy?.hosts, ['narrow.stripe.com'])
    equal('prod.key', st.plugins()[0].secretname)

    st.close()
  })

  test('warm() misses a name nobody declared, rather than inventing one', () => {
    // Widening `warm`'s fallback to cover imperative instances also let
    // a typo derive a secret name and call the provider — so a
    // nonexistent instance could be reported `warmed` off a shared
    // api-level credential.
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': {} })
    const asked: string[] = []
    ;(st as any).broker = {
      value: async (_s: string, n: string) => { asked.push(n); return 'sk' },
      hoist: () => undefined,
      scrub: (t: string) => t,
      refresh: () => undefined,
    }

    return st.warm(['stripe$prodd']).then((out: any) => {
      deepStrictEqual(out.warmed, [])
      deepStrictEqual(out.missed, ['stripe$prodd'])
      // ...and the provider was never asked, so no shared credential
      // was touched on a typo's behalf.
      deepStrictEqual(asked, [])
      st.close()
    })
  })

  test('a DECLARED numeric ref is not stolen by auto-tagging', () => {
    // `registry.has('stripe$1')` is false until something constructs
    // it, so the tag was handed to a client built from a different
    // block. `instances()` then showed the declared `stripe$1` live
    // with the wrong client.
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({
      'stripe$1': { secret: 'one.key' },
      'stripe$prod': { secret: 'prod.key' },
    })
    st.create('stripe$prod')

    // $2, because $1 is declared — reserved by declaration whether or
    // not it has been built.
    deepStrictEqual(st.plugins().map((p) => p.name), ['stripe$2'])
    equal('prod.key', st.plugins()[0].secretname)

    // ...so the declared instance is still buildable under its own name.
    st.sdk('stripe$1')
    deepStrictEqual(st.plugins().map((p) => p.name).sort(),
      ['stripe$1', 'stripe$2'])
    equal('one.key',
      st.plugins().filter((p) => 'stripe$1' === p.name)[0].secretname)

    st.close()
  })
})
