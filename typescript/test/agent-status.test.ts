import { test } from 'node:test'
import * as Assert from 'node:assert'
import * as Fs from 'node:fs'
import * as Os from 'node:os'
import * as Path from 'node:path'

import { Station, featureBinding } from '../src'

const VALUE = 'sk-solar-0123456789'

// A client as sdkgen generates one, with an API key or without.
function fakeSDK(slug: string, auth = true) {
  const config: any = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { ...(auth ? { auth: { prefix: 'Bearer ' } } : {}), server: {} },
    entity: {},
  }
  class SDK {
    _features = [{ name: 'station' }]
    _mode = 'test'
    options: any
    constructor(options: any) {
      this.options = options
      const feature = options?.feature
      const fopts = Array.isArray(feature)
        ? feature.find((f: any) => 'station' === f.name)
        : feature?.station
      featureBinding({
        client: this,
        utility: { fetcher: async () => ({ status: 200 }) },
        options: { apikey: options?.apikey, feature: {} },
        config,
      }, fopts)
    }
  }
  return SDK
}

function station(providers: any[]): Station {
  return new Station({
    config: { station: 1, profiles: { default: { secrets: { providers } } } },
    proxy: 'off', load: false,
  })
}

const PLACEMENT = 'library (R1): this process resolves the secret'

test('secrets() names the store that answers each bound plugin, and never a value', async () => {
  const st = station([
    { kind: 'env', prefix: 'STATIONSECRETSTEST_' },
    { kind: 'memory', values: { SOLAR_APIKEY: VALUE } },
  ])
  st.connect(fakeSDK('solar'), { instance: 'solar' })
  st.connect(fakeSDK('lunar'), { instance: 'lunar' })

  const rows = await st.secrets()
  Assert.deepStrictEqual(rows, [
    {
      plugin: 'solar', secret: 'solar.apikey', placement: PLACEMENT,
      chain: ['env:STATIONSECRETSTEST_', 'memory'], store: 'memory', resolution: 'resolved by memory',
    },
    {
      plugin: 'lunar', secret: 'lunar.apikey', placement: PLACEMENT,
      chain: ['env:STATIONSECRETSTEST_', 'memory'],
      resolution: 'unresolved: no store in the chain has "lunar.apikey"',
      remediation: 'set env var LUNAR_APIKEY, or add "lunar.apikey" to a configured store',
    },
  ])
  Assert.strictEqual(JSON.stringify(rows).includes(VALUE), false)
  st.close()
})

test('secrets() reports the first store in resolution order', async () => {
  process.env.STATIONSECRETSTEST_SOLAR_APIKEY = 'sk-env-0123456789'
  try {
    const st = station([
      { kind: 'env', prefix: 'STATIONSECRETSTEST_' },
      { kind: 'memory', values: { SOLAR_APIKEY: VALUE } },
    ])
    st.connect(fakeSDK('solar'), { instance: 'solar' })
    const [row] = await st.secrets()
    Assert.strictEqual(row.store, 'env')
    Assert.strictEqual(row.resolution, 'resolved by env')
    st.close()
  }
  finally {
    delete process.env.STATIONSECRETSTEST_SOLAR_APIKEY
  }
})

test('a store that cannot answer is an error, never a weaker store that can', async () => {
  const dir = Fs.mkdtempSync(Path.join(Os.tmpdir(), 'station-secrets-'))
  try {
    // A directory where the secret's file should be: the store cannot read it.
    Fs.mkdirSync(Path.join(dir, 'SOLAR_APIKEY'))
    const st = station([
      { kind: 'file', dir },
      { kind: 'memory', values: { SOLAR_APIKEY: VALUE } },
    ])
    st.connect(fakeSDK('solar'), { instance: 'solar' })
    const [row] = await st.secrets()
    Assert.strictEqual(row.store, undefined)
    Assert.match(row.resolution, /^error: .*cannot read/)
    Assert.strictEqual(JSON.stringify(row).includes(VALUE), false)
    st.close()
  }
  finally {
    Fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('secrets() says where adopt() took the key from, and when an API takes none', async () => {
  const st = station([{ kind: 'memory', values: {} }])
  st.adopt(fakeSDK('solar'), { instance: 'solar', apikey: VALUE })
  st.connect(fakeSDK('open', false), { instance: 'open' })

  const rows = await st.secrets()
  Assert.deepStrictEqual(rows.map((r) => [r.plugin, r.resolution]), [
    ['solar', 'hoisted: adopt() took the credential from the SDK\'s own options'],
    ['open', 'none: the API takes no credential'],
  ])
  Assert.strictEqual(rows[1].secret, undefined)
  Assert.strictEqual(JSON.stringify(rows).includes(VALUE), false)
  st.close()
})

test('policies() reports each bound plugin\'s gates as solo mode applies them', () => {
  const st = new Station({
    config: {
      station: 1,
      profiles: {
        default: {
          api: { lunar: { policy: { mode: 'block' } } },
          sdk: {
            solar: {
              agent: { write: true },
              capture: 'headers',
              policy: { hosts: ['api.solar.test'], allow: { op: ['list', 'load'] }, budget: { rps: 5 } },
            },
          },
        },
      },
    },
    proxy: 'off', load: false,
  })
  st.connect(fakeSDK('solar'), { instance: 'solar' })
  st.connect(fakeSDK('lunar'), { instance: 'lunar' })
  st.connect(fakeSDK('open', false), { instance: 'open' })

  Assert.deepStrictEqual(st.policies(), [
    {
      plugin: 'solar', api: 'solar', mode: 'live', hosts: ['api.solar.test'],
      allow: { op: ['list', 'load'] }, budget: { rps: 5 },
      resolve: 'library', capture: 'headers', agentWrite: true,
    },
    { plugin: 'lunar', api: 'lunar', mode: 'block', hosts: null, resolve: 'library', agentWrite: false },
    { plugin: 'open', api: 'open', mode: 'live', hosts: null, resolve: 'library', agentWrite: false },
  ])
  st.close()
})
