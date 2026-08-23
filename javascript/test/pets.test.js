// The awkward cases, against the gnarly-pets test API: Bearer-prefix
// injection, the hosts policy (including the redirect rule at the
// library seam), credential echo kept out of the event stream, and the
// binding forms the js target adds: the inverted st.options() form and
// connect()'s dual path over the generated station feature.
//
// A port of typescript/test/pets.test.ts, which is canonical - this
// port runs against the js target's generated SDK. The generated js
// checkout carries only gnarly-pets, so the multi-plugin registry case
// stays with the ts suite; the generated-feature cases (inverted
// binding, dual-path no-double-bind) live here, where the SDK's config
// carries a real StationFeature class.

const { test, describe, before, after, beforeEach } = require('node:test')
const { equal, ok, match, deepEqual } = require('node:assert')

const { spawn } = require('node:child_process')
const Path = require('node:path')

const Fs = require('node:fs')

const { Station } = require('../src/Station')

const SDK_ROOT = process.env.STATION_TEST_SDKS || '/home/user/voxgig-sdk'
const API_ROOT = Path.join(__dirname, '..', '..', 'test', 'api')

const APIKEY = 'gnarly-pet-key-3'

function loadPets() {
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

describe('gnarly-pets', { skip: !HAVE_SDKS }, () => {

  test('Bearer prefix: the injected value rides behind the prefix', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const pets = station.connect(loadPets())

      // The SDK's auth.prefix is Bearer (from the http/bearer scheme);
      // prepareAuth space-joins prefix + placeholder, and injection
      // swaps only the placeholder - the prefix survives.
      const fetchdef = await pets.prepare({ path: '/api/pet', method: 'GET' })
      equal('Bearer [station:gnarly-pets]', fetchdef.headers['authorization'])

      const result = await pets.Pet().list()
      ok(Array.isArray(result))
      ok(0 < result.length)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('hosts policy denies off-list egress with station_host_allow', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({
        config: {
          station: 1,
          profiles: {
            default: {
              sdk: {
                'gnarly-pets': { policy: { hosts: ['api.other.example'] } },
              },
            },
          },
        },
      })
      const pets = station.connect(loadPets())

      let thrown = null
      try { await pets.Pet().list() }
      catch (e) { thrown = e }
      ok(null != thrown)
      match(String(thrown.message), /station_host_allow/)

      const errs = station.events().filter((e) => 'error' === e.kind)
      equal('station_host_allow', errs[0].err.code)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('a 302 rides back manual under a hosts policy; no offsite follow', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({
        config: {
          station: 1,
          profiles: {
            default: {
              sdk: { 'gnarly-pets': { policy: { hosts: ['localhost'] } } },
            },
          },
        },
      })
      const pets = station.connect(loadPets())

      // The server 302s this path to an offsite host that does not
      // exist - an automatic follow would throw fetch-failed. Manual
      // redirects surface the 302 as an ordinary response instead.
      const out = await pets.direct({ path: '/api/pet/redirect-me', method: 'GET' })
      equal(302, out.status)

      const http = station.events().filter((e) => 'http' === e.kind)
      equal(1, http.length)
      equal(302, http[0].http.status)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('an upstream credential echo never reaches the event stream', async () => {
    // A wrong-but-present credential: the server 401s and echoes the
    // presented value in its error body (deliberately gnarly). Nothing
    // holding the value may appear in events.
    process.env.GNARLY_PETS_APIKEY = 'wrong-value-7'
    try {
      const station = Station.open({ config: null })
      const pets = station.connect(loadPets())

      try { await pets.Pet().list() } catch (_e) { }

      const dump = JSON.stringify(station.events())
      ok(!dump.includes('wrong-value-7'), 'credential leaked into events')
      // The scrub also covers redact() output handed to agents.
      equal('[redacted]', station.redact('wrong-value-7'))

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('one station, one plugin, one status surface', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      station.connect(loadPets())

      const plugins = station.plugins()
      deepEqual(plugins.map((p) => p.slug), ['gnarly-pets'])

      const pets = plugins[0]
      equal('R1', pets.rung)
      equal('GNARLY_PETS', pets.descriptor.envtoken)

      const status = station.status()
      equal('solo', status.mode)
      equal(1, status.plugins.length)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('binding one client class twice is an error', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      station.connect(loadPets())
      let thrown = null
      try { station.connect(loadPets()) }
      catch (e) { thrown = e }
      ok(null != thrown)
      equal('station_bound_twice', thrown.code)
      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('inverted binding: st.options() drives the generated feature', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const SDK = loadPets()

      // The §3.1 inverted form: the app constructs, station only builds
      // the options map - the generated StationFeature does the binding.
      const pets = new SDK(station.options())

      // Placeholder-safe options(), Bearer injection at the wire.
      equal('[station:gnarly-pets]', pets.options().apikey)
      const fetchdef = await pets.prepare({ path: '/api/pet', method: 'GET' })
      equal('Bearer [station:gnarly-pets]', fetchdef.headers['authorization'])

      const result = await pets.Pet().list()
      ok(Array.isArray(result))
      ok(0 < result.length)

      // The op and http events correlate via corr (§3, §6).
      const events = station.events()
      const http = events.filter((e) => 'http' === e.kind)
      const op = events.filter((e) => 'op' === e.kind)
      equal(1, http.length)
      equal(1, op.length)
      equal(http[0].corr, op[0].corr)
      equal(200, http[0].http.status)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })

  test('connect() dual path: generated feature + carried adapter bind once', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      // connect() activates the generated station feature AND rides the
      // carried adapter on extend; both reach featureBinding, and the
      // second arrival is inert (Station._boundEntry) - one client, one
      // registration, one wrap, one event per hop.
      const pets = station.connect(loadPets())

      // Both instances really are present - the dual arrival happened.
      deepEqual(pets._features.map((f) => f.name), ['station', 'station'])

      equal(1, station.plugins().length)
      equal(1, station.events().filter((e) => 'construct' === e.kind).length)

      const result = await pets.Pet().list()
      ok(Array.isArray(result))

      const http = station.events().filter((e) => 'http' === e.kind)
      const op = station.events().filter((e) => 'op' === e.kind)
      equal(1, http.length)
      equal(1, op.length)
      equal(http[0].corr, op[0].corr)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })
})
