// The GENERATED-feature path (sdkgen-station's ts adapter), against the
// live taskpad server: the taskpad SDK here was regenerated with the
// station feature installed via `package add @voxgig/sdkgen-station`, so
// its Config carries a real StationFeature class. Inverted binding rides
// the generated feature alone; connect() rides the generated feature AND
// the carried adapter - _boundEntry makes the second arrival inert
// (design §3.1); with no station open the active feature is a no-op.

import { test, describe, before, after, beforeEach } from 'node:test'
import { equal, ok } from 'node:assert'

import { spawn, ChildProcess } from 'node:child_process'
import * as Path from 'node:path'

import * as Fs from 'node:fs'

import { Station } from '../src/Station'

const SDK_ROOT = process.env.STATION_TEST_SDKS || '/home/user/voxgig-sdk'
const API_ROOT = Path.join(__dirname, '..', '..', '..', 'test', 'api')

const APIKEY = 'taskpad-key-101'

// Own port: this suite runs in parallel with quickstart's server on the
// SDK's default 8902, so it spawns its own instance and overrides base.
const PORT = 8912
const BASE = 'http://localhost:' + PORT

function loadSDK(): any {
  // The generated package compiles to dist/; require the built entry.
  return require(Path.join(SDK_ROOT, 'taskpad-sdk', 'ts', 'dist', 'TaskpadSDK'))
    .TaskpadSDK
}

// The integration suites run against REAL generated SDKs; without a
// generated checkout (STATION_TEST_SDKS) they skip rather than fail.
// This suite additionally needs the regenerated station feature.
const HAVE_SDKS = Fs.existsSync(Path.join(SDK_ROOT, 'taskpad-sdk', 'ts', 'dist',
  'feature', 'station', 'StationFeature.js'))

let server: ChildProcess

before(async function (this: any) {
  if (!HAVE_SDKS) { return }
  server = spawn('node', [Path.join(API_ROOT, 'taskpad', 'server.js')], {
    env: { ...process.env, TASKPAD_APIKEY: APIKEY, TASKPAD_PORT: String(PORT) },
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  await new Promise<void>((resolve, reject) => {
    server.stdout!.on('data', () => resolve())
    server.on('error', reject)
    setTimeout(() => reject(new Error('taskpad server did not start')), 5000)
  })
})

after(() => { server?.kill() })

beforeEach(() => { Station.reset() })

describe('generated-feature', { skip: !HAVE_SDKS }, () => {

  test('inverted binding: new SDK(st.options()) binds and injects', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      const st = Station.open({ config: null })
      const TaskpadSDK = loadSDK()

      // The generated constructor, station-built options - the primary
      // binding form for static languages (§3.1), exercised in ts so the
      // generated feature (not the carried adapter) makes the binding.
      const pad = new TaskpadSDK(st.options({ base: BASE }))

      equal('[station:taskpad]', pad.options().apikey)

      const result = await pad.Todo().list()
      ok(Array.isArray(result), 'list() returns entities')
      ok(0 < result.length)

      const events = st.events()
      const http = events.filter((e) => 'http' === e.kind)
      const op = events.filter((e) => 'op' === e.kind)
      equal(1, http.length)
      equal(1, op.length)
      equal(http[0].corr, op[0].corr)
      equal(200, http[0].http!.status)
      equal('ok', op[0].op!.outcome)

      st.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })

  test('connect() on the regenerated SDK does not double-bind', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      const st = Station.open({ config: null })

      // connect() activates the station entry AND rides the carried
      // adapter on extend, so this construction reaches featureBinding
      // twice - generated feature first, carried adapter second. The
      // second arrival must be inert (_boundEntry), not an error.
      const pad = st.connect(loadSDK(), { base: BASE })

      ok(2 === pad._features.filter((f: any) => 'station' === f.name).length,
        'both the generated feature and the carried adapter are present')

      const construct = st.events().filter((e) => 'construct' === e.kind)
      equal(1, construct.length)
      equal(1, st.plugins().length)

      const result = await pad.Todo().list()
      ok(Array.isArray(result))

      // One wrap, one hook bridge: no doubled events either.
      equal(1, st.events().filter((e) => 'http' === e.kind).length)
      equal(1, st.events().filter((e) => 'op' === e.kind).length)

      st.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })

  test('active feature with no open station is an inert no-op', async () => {
    // No Station.open() anywhere: the activated generated feature finds
    // no handle and no ambient instance, so it binds nothing and fails
    // nothing (§3.1) - the op path runs untouched in test mode.
    const TaskpadSDK = loadSDK()
    const pad = new TaskpadSDK({
      feature: {
        station: { active: true },
        test: { active: true, entity: { todo: { t1: { id: 't1', title: 'inert' } } } },
      },
    })

    const got = (await pad.Todo().load({ id: 't1' })).data()
    equal('inert', got.title)
  })
})
