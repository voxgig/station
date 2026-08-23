// The awkward cases, against the gnarly-pets test API: Bearer-prefix
// injection, the hosts policy (including the redirect rule at the
// library seam), credential echo kept out of the event stream, and a
// multi-plugin registry.

import { test, describe, before, after, beforeEach } from 'node:test'
import { equal, ok, match, deepEqual } from 'node:assert'

import { spawn, ChildProcess } from 'node:child_process'
import * as Path from 'node:path'

import * as Fs from 'node:fs'

import { Station } from '../src/Station'

const SDK_ROOT = process.env.STATION_TEST_SDKS || '/home/user/voxgig-sdk'
const API_ROOT = Path.join(__dirname, '..', '..', '..', 'test', 'api')

const APIKEY = 'gnarly-pet-key-3'

function loadPets(): any {
  return require(Path.join(SDK_ROOT, 'gnarly-pets-sdk', 'ts', 'dist', 'GnarlyPetsSDK'))
    .GnarlyPetsSDK
}
function loadTaskpad(): any {
  return require(Path.join(SDK_ROOT, 'taskpad-sdk', 'ts', 'dist', 'TaskpadSDK'))
    .TaskpadSDK
}
function loadSolardemo(): any {
  return require(Path.join(SDK_ROOT, 'voxgig-solardemo-sdk', 'ts', 'dist', 'SolardemoSDK'))
    .SolardemoSDK
}

// The integration suites run against REAL generated SDKs; without a
// generated checkout (STATION_TEST_SDKS) they skip rather than fail.
const HAVE_SDKS = Fs.existsSync(Path.join(SDK_ROOT, 'gnarly-pets-sdk', 'ts', 'dist'))

let server: ChildProcess

before(async function (this: any) {
  if (!HAVE_SDKS) { return }
  server = spawn('node', [Path.join(API_ROOT, 'gnarly-pets', 'server.js')], {
    env: { ...process.env, GNARLY_PETS_APIKEY: APIKEY },
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  await new Promise<void>((resolve, reject) => {
    server.stdout!.on('data', () => resolve())
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

      let thrown: any = null
      try { await pets.Pet().list() }
      catch (e: any) { thrown = e }
      ok(null != thrown)
      match(String(thrown.message), /station_host_allow/)

      const errs = station.events().filter((e) => 'error' === e.kind)
      equal('station_host_allow', errs[0].err!.code)

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
      equal(302, http[0].http!.status)

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

  test('one station, three plugins, one status surface', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    process.env.TASKPAD_APIKEY = 'taskpad-key-101'
    try {
      const station = Station.open({ config: null })
      station.connect(loadPets())
      station.connect(loadTaskpad())
      station.connect(loadSolardemo())

      const plugins = station.plugins()
      deepEqual(plugins.map((p) => p.slug).sort(),
        ['gnarly-pets', 'solardemo', 'taskpad'])

      // solardemo's model declares no auth: rung 'none', everything
      // else still applies (design §5.3).
      const solar = plugins.find((p) => 'solardemo' === p.slug)!
      equal('none', solar.rung)
      const pets = plugins.find((p) => 'gnarly-pets' === p.slug)!
      equal('R1', pets.rung)
      equal('GNARLY_PETS', pets.descriptor.envtoken)

      const status = station.status()
      equal('solo', status.mode)
      equal(3, status.plugins.length)

      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
      delete process.env.TASKPAD_APIKEY
    }
  })

  test('binding one client class twice is an error', async () => {
    process.env.GNARLY_PETS_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      station.connect(loadPets())
      let thrown: any = null
      try { station.connect(loadPets()) }
      catch (e: any) { thrown = e }
      ok(null != thrown)
      equal('station_bound_twice', thrown.code)
      station.close()
    }
    finally {
      delete process.env.GNARLY_PETS_APIKEY
    }
  })
})
