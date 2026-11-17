
import { beforeEach, test } from 'node:test'
import * as Assert from 'node:assert'

import { Station } from '../src/Station'
import { BOUND_POINT, FEATURE_POINT, withfeature } from '../src/extension'
import { provide, resetFactories } from '../src/factory'

function station(): Station {
  return new Station({ config: null, proxy: 'off', load: false })
}

test('use takes an extension live, and it reads the station', () => {
  const st = station()
  let seen: any
  st.use({
    name: 'probe',
    activate(inst: any) {
      seen = inst.host().exports('station/station')
      inst.export('probe', { mode: seen.status().mode, options: inst.options })
    },
  }, { colour: 'blue' })

  Assert.strictEqual(seen, st)
  Assert.deepStrictEqual(st.extensions(), [{ name: 'probe', status: 'live' }])
  Assert.deepStrictEqual(st.extension('probe/probe'), { mode: 'solo', options: { colour: 'blue' } })
  st.close()
})

test('close takes every extension down, and leaves none listed', () => {
  const st = station()
  const log: string[] = []
  for (const name of ['alpha', 'zeta']) {
    st.use({
      name,
      activate(inst: any) { inst.release(() => log.push('release ' + name)) },
      close() { log.push('close ' + name) },
    })
  }

  st.close()
  Assert.deepStrictEqual(log.sort(), ['close alpha', 'close zeta', 'release alpha', 'release zeta'])
  Assert.deepStrictEqual(st.extensions(), [])
})

test('a station that is never extended lists none', () => {
  const st = station()
  Assert.deepStrictEqual(st.extensions(), [])
  Assert.strictEqual(st.extension('view/view'), undefined)
  st.close()
})

test('an extension may not take the name station', () => {
  const st = station()
  Assert.throws(() => st.use({ name: 'station' }),
    (err: any) => 'plugin_ref_reserved' === err.code)
  st.close()
})

test('use is idempotent for one definition, and refuses another under its name', () => {
  const st = station()
  let activations = 0
  const def = { name: 'once', activate() { activations++ } }
  st.use(def).use(def)
  Assert.strictEqual(activations, 1)
  Assert.throws(() => st.use({ name: 'once' }),
    (err: any) => 'plugin_ref_duplicate' === err.code)
  st.close()
})

test('a closed station takes no extension', () => {
  const st = station()
  st.close()
  Assert.throws(() => st.use({ name: 'late' }),
    (err: any) => 'station_no_plugin' === err.code && /station is closed/.test(err.message))
  Assert.deepStrictEqual(st.extensions(), [])
})

test('a name Object.prototype holds is refused as a bad name, before the host sees it', () => {
  const st = station()
  for (const name of ['constructor', 'toString', 'hasOwnProperty']) {
    Assert.throws(() => st.use({ name }), (err: any) => 'plugin_bad_name' === err.code, name)
  }
  Assert.deepStrictEqual(st.extensions(), [])
  st.use({ name: 'tostring' })
  Assert.deepStrictEqual(st.extensions(), [{ name: 'tostring', status: 'live' }])
  st.close()
})

test('an extension that fails to activate raises and is listed failed', () => {
  const st = station()
  Assert.throws(() => st.use({ name: 'broken', activate() { throw new Error('no') } }),
    (err: any) => 'plugin_activate_failed' === err.code)
  Assert.deepStrictEqual(st.extensions(), [{ name: 'broken', status: 'failed' }])
  st.close()
})

test('extensions are not plugins: plugins() and status() list bound SDKs only', () => {
  const st = station()
  st.use({ name: 'probe' })
  Assert.deepStrictEqual(st.plugins(), [])
  Assert.deepStrictEqual(st.status().plugins, [])
  st.close()
})


// What a generated SDK reads from sdkgen's list form: the entries by name.
function byname(feature: any): any {
  return Array.isArray(feature)
    ? Object.fromEntries(feature.map(({ name, ...rest }: any) => [name, rest]))
    : feature || {}
}

function fakeSDK(slug: string, feature?: Record<string, any>) {
  const config: any = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { auth: { prefix: 'Bearer ' }, server: {} },
    entity: {},
    ...(null == feature ? {} : { feature }),
  }
  const seen: any[] = []
  class SDK {
    options: any
    _features = [{ name: 'station' }]
    _mode = 'test'
    constructor(options: any) {
      this.options = options
      seen.push(options)
      const fopts = byname(options?.feature).station
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
  provide(slug, { construct: (o: any) => new SDK(o), config })
  return { SDK, seen }
}

function profiled(sdk: Record<string, any>): Station {
  return new Station({ config: { station: 1, profiles: { default: { sdk } } }, proxy: 'off' })
}

// An extension that switches one feature on in every SDK that has it.
function adder(feature: string, entry: any) {
  return {
    name: 'add-' + feature,
    define(inst: any) {
      inst.bind(FEATURE_POINT, (next: any, given: any, info: any) =>
        next(withfeature(given, feature, entry, info.descriptor), info))
    },
  }
}

function warned(st: Station, pattern: RegExp): boolean {
  return st.events().some((e: any) => 'station' === e.kind && pattern.test(e.meta?.warn ?? ''))
}

beforeEach(() => resetFactories())

test('an extension switches a feature on in each SDK built that has it, and in no other', () => {
  const solar = fakeSDK('solar', { telemetry: { options: { active: false } } })
  const plain = fakeSDK('plain')
  const st = profiled({ solar: {}, plain: {}, 'solar$b': {} })
  st.use(adder('telemetry', { active: true }))

  st.sdk('solar')
  st.create('solar')
  st.connect(solar.SDK, { instance: 'solar$b' })
  new solar.SDK(st.options('solar$c', {}))
  st.sdk('plain')

  Assert.deepStrictEqual(solar.seen.map((o) => byname(o.feature).telemetry?.active),
    [true, true, true, true])
  Assert.strictEqual(byname(plain.seen[0].feature).telemetry, undefined)
  st.close()
})

test('a connect that names no instance tells the extensions nothing of its SDK', () => {
  const solar = fakeSDK('solar', { telemetry: {} })
  const infos: any[] = []
  const st = new Station({ config: null, proxy: 'off', load: false })
  st.use({
    name: 'probe',
    define(inst: any) {
      inst.bind(FEATURE_POINT, (next: any, feature: any, info: any) => {
        infos.push(info)
        return next(feature, info)
      })
    },
  })

  st.connect(solar.SDK, { instance: 'solar$a' })
  st.connect(solar.SDK)

  Assert.deepStrictEqual(infos.map((i) => [i.name, i.api, i.descriptor?.slug]),
    [['solar$a', 'solar', 'solar'], [undefined, undefined, undefined]])
  st.close()
})

test('an extension sees the caller\'s features, never the key or station\'s own entry', () => {
  const solar = fakeSDK('solar', { telemetry: {} })
  let given: any
  const st = new Station({ config: null, proxy: 'off', load: false })
  st.use({
    name: 'probe',
    define(inst: any) {
      inst.bind(FEATURE_POINT, (next: any, feature: any, info: any) => {
        given = feature
        return next(feature, info)
      })
    },
  })

  st.connect(solar.SDK, {
    instance: 'solar$a', apikey: 'sk-live-0123456789abcdef',
    feature: { retry: { active: true } },
  })

  Assert.deepStrictEqual(given, { retry: { active: true } })
  Assert.ok(!JSON.stringify(solar.seen[0].feature.station.calleropts).includes('sk-live'))
  st.close()
})

test('in the list form a feature is merged in place or appended, and station keeps its place', () => {
  const solar = fakeSDK('solar', { telemetry: {}, retry: {}, test: {} })
  const st = new Station({ config: null, proxy: 'off', load: false })
  st.use(adder('telemetry', { active: true, max: 50 }))

  st.connect(solar.SDK, {
    instance: 'solar$a',
    feature: [{ name: 'test', active: true }, { name: 'retry', active: true }],
  })
  st.connect(solar.SDK, {
    instance: 'solar$b',
    feature: [{ name: 'telemetry', max: 5 }, { name: 'retry', active: true }],
  })

  Assert.deepStrictEqual(solar.seen[0].feature.map((f: any) => f.name),
    ['test', 'station', 'retry', 'telemetry'])
  Assert.deepStrictEqual(solar.seen[1].feature.map((f: any) => f.name),
    ['station', 'telemetry', 'retry'])
  Assert.deepStrictEqual(byname(solar.seen[1].feature).telemetry, { active: true, max: 5 })
  st.close()
})

test('the caller\'s settings win, and where both set a function both run, the caller\'s first', () => {
  const calls: string[] = []
  const descriptor = { features: [{ name: 'telemetry' }] }
  const out = withfeature(
    { telemetry: { active: false, max: 5, exporter: () => { calls.push('caller'); return 'kept' } } },
    'telemetry',
    { active: true, max: 50, idgen: 'x', exporter: () => { calls.push('view'); throw new Error('no') } },
    descriptor)

  Assert.strictEqual(out.telemetry.active, false)
  Assert.strictEqual(out.telemetry.max, 5)
  Assert.strictEqual(out.telemetry.idgen, 'x')
  Assert.strictEqual(out.telemetry.exporter('span'), 'kept')
  Assert.deepStrictEqual(calls, ['caller', 'view'])

  const feature = { retry: { active: true } }
  Assert.strictEqual(withfeature(feature, 'telemetry', { active: true }, undefined), feature)
  Assert.strictEqual(withfeature(feature, 'telemetry', { active: true }, { features: [] }), feature)
})

test('a failing extension leaves the features as the caller gave them, and says so', () => {
  const solar = fakeSDK('solar', { telemetry: {} })
  const st = new Station({ config: null, proxy: 'off', load: false })
  st.use(adder('telemetry', { active: true }))
  st.use({
    name: 'broken',
    define(inst: any) { inst.bind(FEATURE_POINT, () => { throw new Error('bad amend') }) },
  })

  const client = st.connect(solar.SDK, { instance: 'solar$a', feature: { retry: { active: true } } })

  Assert.ok(client)
  Assert.deepStrictEqual(Object.keys(byname(solar.seen[0].feature)).sort(), ['retry', 'station'])
  Assert.ok(warned(st, /^an extension failed at sdk\.feature: bad amend$/))
  st.close()
})

test('each bound client is told to every extension, and one that fails does not stop the rest', () => {
  const solar = fakeSDK('solar')
  const told: any[] = []
  const st = profiled({ solar: {} })
  st.use({
    name: 'one',
    define(inst: any) { inst.bind(BOUND_POINT, () => { throw new Error('one fails') }) },
  })
  st.use({
    name: 'two',
    define(inst: any) { inst.bind(BOUND_POINT, (sdk: any) => { told.push(sdk) }) },
  })

  const first = st.connect(solar.SDK, { instance: 'solar$a' })
  const second = st.sdk('solar')

  Assert.deepStrictEqual(told.map((t) => [t.name, t.api, t.descriptor.slug]),
    [['solar$a', 'solar', 'solar'], ['solar', 'solar', 'solar']])
  Assert.strictEqual(told[0].client, first)
  Assert.strictEqual(told[1].client, second)
  Assert.ok(warned(st, /^an extension failed at sdk\.bound: one fails$/))
  st.close()
})

test('an extension learns only of clients bound after it is used', () => {
  const solar = fakeSDK('solar')
  const told: any[] = []
  const st = new Station({ config: null, proxy: 'off', load: false })
  st.connect(solar.SDK, { instance: 'solar$a' })
  st.use({
    name: 'late',
    define(inst: any) { inst.bind(BOUND_POINT, (sdk: any) => { told.push(sdk.name) }) },
  })
  st.connect(solar.SDK, { instance: 'solar$b' })

  Assert.deepStrictEqual(told, ['solar$b'])
  st.close()
})

