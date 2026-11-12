import { after, beforeEach, describe, test } from 'node:test'
import { deepStrictEqual, equal } from 'node:assert'

import { Station } from '../src/Station'
import { adapterAnchor } from '../src/adapter'
import { provide, resetFactories } from '../src/factory'

// What an SDK generated without the station feature does when it is
// constructed: makeOptions' feature order, the constructor's loops,
// featureAdd's anchors and featureInit, as sdkgen's ts templates write
// them. `statuses` scripts the wire, one status per attempt.
function generatedSDK(slug: string, statuses: number[]) {
  const config: any = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { auth: { prefix: '' }, server: {} },
    entity: {},
    feature: {
      cache: { options: { active: false } },
      retry: { options: { active: false } },
      test: { options: { active: false } },
    },
  }

  const sent: string[] = []
  const wire = async (_ctx: any, url: string) => {
    sent.push(url)
    return { status: statuses[sent.length - 1] ?? 200, headers: { get: () => null } }
  }

  const makeFeature = (name: string): any => ({
    name,
    init(ctx: any) {
      const inner = ctx.utility.fetcher
      if ('test' === name) {
        ctx.utility.fetcher = async () => ({ status: 200, headers: { get: () => null } })
      }
      else if ('retry' === name) {
        ctx.utility.fetcher = async (c: any, url: string, def: any) => {
          let res = await inner(c, url, def)
          for (let i = 0; i < 2 && 503 === res.status; i++) { res = await inner(c, url, def) }
          return res
        }
      }
      else {
        ctx.utility.fetcher = async (c: any, url: string, def: any) => inner(c, url, def)
      }
    },
  })

  const featureorder = (fmap: any): string[] => {
    let names = Object.keys(fmap || {}).sort()
    names = names.indexOf('test') < 0 ? names
      : ['test'].concat(names.filter((n) => 'test' !== n))
    const si = names.indexOf('station')
    if (0 <= si) {
      names.splice(si, 1)
      names.splice(names.indexOf('test') + 1, 0, 'station')
    }
    return names
  }

  const featureAdd = (client: any, f: any) => {
    const fopts = f._options || {}
    const features = client._features
    for (let i = 0; i < features.length; i++) {
      const name = features[i].name
      if (fopts.__before__ === name) { features.splice(i, 0, f); return }
      if (fopts.__after__ === name) { features.splice(i + 1, 0, f); return }
      if (fopts.__replace__ === name) { features[i] = f; return }
    }
    features.push(f)
  }

  class SDK {
    _mode = 'live'
    _features: any[] = []
    _ctx: any

    constructor(options: any) {
      const opts = { ...options, feature: options?.feature || {} }
      this._ctx = { client: this, utility: { fetcher: wire }, options: opts, config }
      if (true === opts.feature.test?.active) { this._mode = 'test' }

      const extend = opts.extend || []
      for (const fname of featureorder(opts.feature)) {
        if (opts.feature[fname]?.active) {
          if (null == config.feature[fname] && extend.some((f: any) => fname === f.name)) {
            continue
          }
          featureAdd(this, makeFeature(fname))
        }
      }
      for (const f of extend) { featureAdd(this, f) }
      for (const f of this._features) {
        const fopts = opts.feature[f.name] || {}
        if (true === fopts.active) { f.init(this._ctx, fopts) }
      }
    }

    async list(): Promise<any> {
      const ctx: any = { client: this, op: { entity: 'todo', name: 'list' } }
      for (const f of this._features) { f.PrePoint?.(ctx) }
      const res = await this._ctx.utility.fetcher(ctx, 'http://api.test/todo', {
        method: 'GET', headers: {},
      })
      ctx.result = { ok: 200 === res.status, status: res.status }
      for (const f of this._features) { f.PreDone?.(ctx) }
      return res
    }
  }

  return { SDK, config, sent }
}

function names(client: any): string[] {
  return client._features.map((f: any) => f.name)
}

function wire(station: Station): any[] {
  return station.events()
    .filter((e) => 'http' === e.kind || 'op' === e.kind)
    .map((e) => [e.kind, e.http?.status ?? e.op?.outcome])
}

describe('adapterAnchor', () => {
  test('after test when test is active, else before the first feature it will add', () => {
    deepStrictEqual(adapterAnchor(undefined), {})
    deepStrictEqual(adapterAnchor({}), {})
    deepStrictEqual(adapterAnchor({ station: { active: true } }), {})
    deepStrictEqual(adapterAnchor({ retry: { active: true } }), { __before__: 'retry' })
    deepStrictEqual(adapterAnchor({ retry: { active: true }, cache: { active: true } }),
      { __before__: 'cache' })
    deepStrictEqual(adapterAnchor({ cache: { active: false }, retry: { active: true } }),
      { __before__: 'retry' })
    deepStrictEqual(adapterAnchor({ station: { active: true }, timeout: { active: true } }),
      { __before__: 'timeout' })
    deepStrictEqual(adapterAnchor({ test: { active: true }, retry: { active: true } }),
      { __after__: 'test' })
    deepStrictEqual(adapterAnchor({ test: { active: false }, retry: { active: true } }),
      { __before__: 'retry' })
    // sdkgen's ordered array form: array order is init order, not the alphabet.
    deepStrictEqual(adapterAnchor([{ name: 'retry', active: true }]), { __before__: 'retry' })
    deepStrictEqual(adapterAnchor([{ name: 'retry', active: true }, { name: 'cache', active: true }]),
      { __before__: 'retry' })
    deepStrictEqual(adapterAnchor([{ name: 'retry', active: true }, { name: 'test', active: true }]),
      { __after__: 'test' })
    deepStrictEqual(adapterAnchor([{ name: 'station', active: true }, { name: 'retry' }]), {})
  })
})

describe('the carried adapter in a generated constructor', () => {
  beforeEach(() => {
    Station.reset()
    process.env.TASKPAD_APIKEY = 'taskpad-key'
  })
  after(() => {
    resetFactories()
    delete process.env.TASKPAD_APIKEY
  })

  test('live, with retry: station is the base wrap and sees each attempt', async () => {
    const { SDK, sent } = generatedSDK('taskpad', [503, 200])
    const station = Station.open({ config: null })
    const client = station.connect(SDK, { feature: { retry: { active: true } } })

    deepStrictEqual(names(client), ['station', 'retry'])
    await client.list()

    equal(sent.length, 2)
    deepStrictEqual(wire(station), [['http', 503], ['http', 200], ['op', 'ok']])
    station.close()
  })

  test('live, with two features: station comes before the first by name', () => {
    const { SDK } = generatedSDK('taskpad', [])
    const station = Station.open({ config: null })
    const client = station.adopt(SDK, {
      feature: { retry: { active: true }, cache: { active: true } },
    })
    deepStrictEqual(names(client), ['station', 'cache', 'retry'])
    station.close()
  })

  test('test mode: station sits on the mock transport', () => {
    const { SDK } = generatedSDK('taskpad', [])
    const station = Station.open({ config: null })
    const client = station.connect(SDK, {
      feature: { test: { active: true }, retry: { active: true } },
    })
    deepStrictEqual(names(client), ['test', 'station', 'retry'])
    station.close()
  })

  test('no other feature: station alone', () => {
    const { SDK } = generatedSDK('taskpad', [])
    const station = Station.open({ config: null })
    deepStrictEqual(names(station.connect(SDK)), ['station'])
    station.close()
  })

  test('the declarative path places it the same way', async () => {
    resetFactories()
    const { SDK, config, sent } = generatedSDK('taskpad', [503, 200])
    provide('taskpad', { construct: (o: any) => new SDK(o), config })
    const station = new Station({
      config: {
        station: 1,
        profiles: { default: { sdk: { taskpad: { feature: { retry: {} } } } } },
      },
    })
    const client = station.sdk('taskpad')

    deepStrictEqual(names(client), ['station', 'retry'])
    await client.list()
    equal(sent.length, 2)
    deepStrictEqual(wire(station), [['http', 503], ['http', 200], ['op', 'ok']])
    station.close()
  })
})
