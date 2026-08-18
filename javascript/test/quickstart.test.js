// The §11 walkthroughs, run for real: the two-line quickstart against a
// live test API, injection at the transport seam, placeholder-safe
// options()/prepare(), and the event stream. The SDK is a REAL generated
// SDK (gnarly-pets, built by sdkgen from an OpenAPI spec) served by the
// gnarly-pets test server - nothing here is mocked.
//
// A port of typescript/test/quickstart.test.ts, which is canonical -
// this port runs against the js target's generated SDK, so the plugin
// is gnarly-pets (the js SDK this checkout generates) rather than
// taskpad, and the auth prefix is Bearer.

const { test, describe, before, after, beforeEach } = require('node:test')
const { equal, ok, deepEqual, match } = require('node:assert')

const { spawn } = require('node:child_process')
const Path = require('node:path')

const Fs = require('node:fs')

const { Station } = require('../src/Station')

const SDK_ROOT = process.env.STATION_TEST_SDKS || '/home/user/voxgig-sdk'
const API_ROOT = Path.join(__dirname, '..', '..', 'test', 'api')

const APIKEY = 'gnarly-pet-key-3'

function loadSDK() {
  // The generated js package runs straight from src; require the entry.
  return require(Path.join(SDK_ROOT, 'gnarly-pets-sdk', 'js', 'src', 'GnarlyPetsSDK'))
    .GnarlyPetsSDK
}

// The integration suites run against REAL generated SDKs; without a
// generated checkout (STATION_TEST_SDKS) they skip rather than fail.
const HAVE_SDKS = Fs.existsSync(Path.join(SDK_ROOT, 'gnarly-pets-sdk', 'js', 'src'))

let server

before(async () => {
  if (!HAVE_SDKS) { return }
  server = spawn('node', [Path.join(API_ROOT, 'gnarly-pets', 'server.js')], {
    env: { ...process.env, GNARLY_PETS_APIKEY: APIKEY },
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  await new Promise((resolve, reject) => {
    server.stdout.on('data', () => resolve())
    server.on('error', reject)
    setTimeout(() => reject(new Error('gnarly-pets server did not start')), 5000)
  })
})

after(() => { server?.kill() })

beforeEach(() => { Station.reset() })

describe('quickstart', { skip: !HAVE_SDKS }, () => {

  test('two lines, secret from the documented env var', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const pets = station.connect(loadSDK())

      const result = await pets.Pet().list()
      ok(Array.isArray(result), 'list() returns entities')
      ok(0 < result.length)

      // The op and http events correlate via corr (§3, §6).
      const events = station.events()
      const http = events.filter((e) => 'http' === e.kind)
      const op = events.filter((e) => 'op' === e.kind)
      equal(1, http.length)
      equal(1, op.length)
      equal(http[0].corr, op[0].corr)
      equal(200, http[0].http.status)
      equal('pet', op[0].op.entity)
      equal('list', op[0].op.op)
      equal('ok', op[0].op.outcome)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('options() and prepare() are placeholder-safe (R1)', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const pets = station.connect(loadSDK())

      // The key is out of app code's way: options() never exposes the
      // value, prepare() output is safe to hand to an agent (§5.3, §11).
      const opts = pets.options()
      equal('[station:gnarly-pets]', opts.apikey)

      const fetchdef = await pets.prepare({ path: '/api/pet', method: 'GET' })
      match(JSON.stringify(fetchdef.headers), /\[station:gnarly-pets\]/)
      ok(!JSON.stringify(fetchdef).includes(APIKEY))

      // And the wire still gets the real value.
      const result = await pets.Pet().list()
      ok(Array.isArray(result))

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('adopt hoists a resident credential', async () => {
    const station = Station.open({ config: null })
    const pets = station.adopt(loadSDK(), { apikey: APIKEY })

    equal('[station:gnarly-pets]', pets.options().apikey)

    const result = await pets.Pet().list()
    ok(Array.isArray(result))

    const warns = station.events().filter((e) =>
      'station' === e.kind && /hoisted/.test(String(e.meta?.warn || '')))
    equal(1, warns.length)

    station.close()
  })

  test('a missing secret is station_secret_no_value on the op path', async () => {
    delete process.env.GNARLY_PETS_APIKEY
    const station = Station.open({ config: null })
    const pets = station.connect(loadSDK())

    let thrown = null
    try { await pets.Pet().list() }
    catch (e) { thrown = e }
    ok(null != thrown, 'op failed')
    match(String(thrown.message), /station_secret_no_value/)

    const errs = station.events().filter((e) => 'error' === e.kind)
    equal(1, errs.length)
    equal('station_secret_no_value', errs[0].err.code)

    station.close()
  })

  test('descriptor carries slug/version/target from the embedded config', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      station.connect(loadSDK())

      const d = station.descriptorOf('gnarly-pets')
      equal('gnarly-pets', d.slug)
      equal('GNARLY_PETS', d.envtoken)
      equal('js', d.target)
      equal('0.0.1', d.version)
      equal('gnarly_pets.apikey', d.auth.secretname)
      deepEqual(Object.keys(d.entities), ['pet', 'visit'])
      ok(d.entities.pet.ops.list)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('test feature stays mocked: no injection into mock transports', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const SDK = loadSDK()
      const pets = station.connect(SDK, {
        feature: { test: { active: true, entity: { pet: { p9: { id: 'p9', name: 'mock' } } } } },
      })

      const got = (await pets.Pet().load({ id: 'p9' })).data()
      equal('mock', got.name)

      // The http event saw the mock attempt; the placeholder was never
      // swapped (mode !== live), so no real value entered the mock store.
      const http = station.events().filter((e) => 'http' === e.kind)
      equal(1, http.length)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })
})
