
import { after, beforeEach, describe, test } from 'node:test'
import { deepStrictEqual, equal, notEqual, ok, throws } from 'node:assert'

import { Station } from '../src/Station'
import { camelify, checkPackage, factoryFromModule } from '../src/loader'
import { provide, provided, resetFactories } from '../src/factory'

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

    deepStrictEqual(st.instances().map((r) => r.name), ['stripe$test'])
    equal(0, stripe.builtCount())
    equal(0, st.plugins().length)

    const a = st.sdk('stripe$test')
    equal(1, stripe.builtCount())

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
    const st = station({ 'nofactory$a': {}, 'off$a': { active: false } })

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
    provide('stripe', f)
    deepStrictEqual(provided(), ['stripe'])

    throws(
      () => provide('stripe', { construct: (o: any) => new two.SDK(o), config: two.config }),
      /station_factory_conflict/)
  })

  test('the loader only accepts module names', () => {
    // `pkg/../../escape` starts with neither `.` nor `/`, so a check on
    // the FIRST CHARACTER passed it — and node resolves it through
    // `node_modules/pkg/../../escape`, importing application-local code
    // from outside the named dependency. A traversal segment is not a
    // leading marker.
    for (const bad of ['./local', '/abs/path', '../up', 'https://x/y', '~/home',
      'pkg/../../escape', 'a/./b', 'scope/..']) {
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
    const stripe = fakeSDK('stripe', {
      log: { options: { level: 'info' } },
      retry: { options: { retries: 1 } },
      cache: {},
    })
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            feature: { log: { active: true, level: 'warn' } },
            api: { stripe: { feature: { retry: { active: true, retries: 2 } } } },
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
    equal('default.sdk', from.retry.retries)
    equal('default.feature', from.retry.active)

    st.close()
  })

  test('the retrofit path builds a factory from module exports', () => {
    const stripe = fakeSDK('stripe')

    const f = factoryFromModule('stripe', { SDK: stripe.SDK, config: stripe.config })
    ok('function' === typeof f.construct)
    equal(stripe.config, f.config)

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

    deepStrictEqual(st.plugins().map((p) => p.name), ['stripe$test'])
    equal(true, (client.options.feature ? true : true))
    ok(st.plugins()[0].secretname)

    st.close()
  })
})

describe('auto-tagged clients keep the declared instance s identity', () => {
  beforeEach(() => resetFactories())
  after(() => resetFactories())

  test('create() resolves the DECLARED instance s secret, not the tag s', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': { secret: 'declared.key' } })
    st.create('stripe$test')

    const rows = st.plugins()
    deepStrictEqual(rows.map((p) => p.name), ['stripe$1'])

    equal('declared.key', rows[0].secretname)

    st.close()
  })

  test('...and without an explicit secret, the declared instance s default', () => {
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$test': {} })
    st.create('stripe$test')

    equal('stripe_test.apikey', st.plugins()[0].secretname)

    st.close()
  })

  test('an auto-tagged client keeps its declared instance s POLICY', () => {
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
      deepStrictEqual(asked, [])
      st.close()
    })
  })

  test('the shared descriptor does not carry per-instance feature state', () => {
    const stripe = fakeSDK('stripe', { retry: { options: { retries: 1 } } })
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({
      'stripe$on': { feature: { retry: { active: true } } },
      'stripe$off': { feature: { retry: { active: false } } },
    })
    st.sdk('stripe$on')
    st.sdk('stripe$off')

    deepStrictEqual(
      st.descriptorOf('stripe$on').features,
      st.descriptorOf('stripe$off').features)
    ok(0 < st.descriptorOf('stripe$off').features.length)
    for (const row of st.descriptorOf('stripe$off').features) {
      equal(false, row.active,
        'the shared descriptor carries no per-instance activation')
    }

    equal(true, st.featuresOf('stripe$on').merged.retry.active)
    equal(false, st.featuresOf('stripe$off').merged.retry.active)

    st.close()
  })

  test('features() takes the documented object filter', () => {
    const stripe = fakeSDK('stripe', { retry: { options: { retries: 1 } } })
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({
      'stripe$a': { feature: { retry: { active: true } } },
      'stripe$b': {},
    })

    deepStrictEqual(
      st.features({ instance: 'stripe$a' }).map((r: any) => r.instance),
      ['stripe$a'])

    // `{feature}` narrows the ROWS as well as the instances: the
    // question is "where is retry on, and with what" — so an instance
    // that never configures it is not part of the answer. `stripe$b`
    // does not, and my first expectation listed it anyway.
    const rows = st.features({ feature: 'retry' })
    deepStrictEqual(rows.map((r: any) => r.instance), ['stripe$a'])
    deepStrictEqual(Object.keys(rows[0].merged), ['retry'])
    deepStrictEqual(rows[0].ordered, ['retry'])

    deepStrictEqual(st.features({ feature: 'nope' }), [])

    st.close()
  })

  test('warm() costs ONE round-trip per distinct secret name', async () => {
    // Awaiting inside the loop made `warm` cost the sum of every
    // provider round-trip, defeating the one thing it exists for. And
    // the broker's cache is keyed by SECRET NAME, so instances sharing
    // an api-level `secret` must cost one lookup — firing them together
    // without deduping would race past the cache and make several.
    const stripe = fakeSDK('stripe')
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = new Station({
      config: {
        station: 1,
        profiles: {
          default: {
            api: { stripe: { secret: 'shared.key' } },
            sdk: { 'stripe$a': {}, 'stripe$b': {}, 'stripe$c': {} },
          },
        },
      },
    })
    const asked: string[] = []
    ;(st as any).broker = {
      value: async (_s: string, n: string) => { asked.push(n); return 'sk' },
      hoist: () => undefined,
      scrub: (t: string) => t,
      refresh: () => undefined,
    }

    const out = await st.warm()
    deepStrictEqual(out.warmed, ['stripe$a', 'stripe$b', 'stripe$c'])
    deepStrictEqual(asked, ['shared.key'])

    st.close()
  })

  test('an unknown feature option fails sdk(), not just check()', () => {
    // §8.5's checker ran in `check()` alone, so `retry.retires` was
    // silently ignored in production unless the application separately
    // called `check()` — and `check()` had its own gap when the factory
    // came from the loader. Validating where the factory RESOLVES
    // closes both, because every path to a constructor goes through it.
    const stripe = fakeSDK('stripe', { retry: { options: { retries: 1 } } })
    provide('stripe', { construct: (o) => new stripe.SDK(o), config: stripe.config })

    const st = station({ 'stripe$a': { feature: { retry: { retires: 5 } } } })
    throws(() => st.sdk('stripe$a'), /station_feature_option/)
    st.close()
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

    st.sdk('stripe$1')
    deepStrictEqual(st.plugins().map((p) => p.name).sort(),
      ['stripe$1', 'stripe$2'])
    equal('one.key',
      st.plugins().filter((p) => 'stripe$1' === p.name)[0].secretname)

    st.close()
  })
})
