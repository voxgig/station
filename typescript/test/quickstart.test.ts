// The §11 walkthroughs, run for real: the two-line quickstart against a
// live test API, injection at the transport seam, placeholder-safe
// options()/prepare(), and the event stream. The SDK is a REAL generated
// SDK (taskpad, built by sdkgen from an OpenAPI spec) served by the
// taskpad test server - nothing here is mocked.

import { test, describe, before, after, beforeEach } from 'node:test'
import { equal, ok, deepEqual, match } from 'node:assert'

import { spawn, ChildProcess } from 'node:child_process'
import * as Path from 'node:path'

import * as Fs from 'node:fs'

import { Station } from '../src/Station'

const SDK_ROOT = process.env.STATION_TEST_SDKS || '/home/user/voxgig-sdk'
const API_ROOT = Path.join(__dirname, '..', '..', '..', 'test', 'api')

const APIKEY = 'taskpad-key-101'

function loadSDK(): any {
  // The generated package compiles to dist/; require the built entry.
  return require(Path.join(SDK_ROOT, 'taskpad-sdk', 'ts', 'dist', 'TaskpadSDK'))
    .TaskpadSDK
}

// The integration suites run against REAL generated SDKs; without a
// generated checkout (STATION_TEST_SDKS) they skip rather than fail.
const HAVE_SDKS = Fs.existsSync(Path.join(SDK_ROOT, 'taskpad-sdk', 'ts', 'dist'))

let server: ChildProcess

before(async function (this: any) {
  if (!HAVE_SDKS) { return }
  server = spawn('node', [Path.join(API_ROOT, 'taskpad', 'server.js')], {
    env: { ...process.env, TASKPAD_APIKEY: APIKEY },
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

describe('quickstart', { skip: !HAVE_SDKS }, () => {

  test('two lines, secret from the documented env var', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const pad = station.connect(loadSDK())

      const result = await pad.Todo().list()
      ok(Array.isArray(result), 'list() returns entities')
      ok(0 < result.length)

      // The op and http events correlate via corr (§3, §6).
      const events = station.events()
      const http = events.filter((e) => 'http' === e.kind)
      const op = events.filter((e) => 'op' === e.kind)
      equal(1, http.length)
      equal(1, op.length)
      equal(http[0].corr, op[0].corr)
      equal(200, http[0].http!.status)
      equal('todo', op[0].op!.entity)
      equal('list', op[0].op!.op)
      equal('ok', op[0].op!.outcome)

      station.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })

  test('options() and prepare() are placeholder-safe (R1)', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const pad = station.connect(loadSDK())

      // The key is out of app code's way: options() never exposes the
      // value, prepare() output is safe to hand to an agent (§5.3, §11).
      const opts = pad.options()
      equal('[station:taskpad]', opts.apikey)

      const fetchdef = await pad.prepare({ path: '/api/todo', method: 'GET' })
      match(JSON.stringify(fetchdef.headers), /\[station:taskpad\]/)
      ok(!JSON.stringify(fetchdef).includes(APIKEY))

      // And the wire still gets the real value.
      const result = await pad.Todo().list()
      ok(Array.isArray(result))

      station.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })

  test('adopt hoists a resident credential', async () => {
    const station = Station.open({ config: null })
    const pad = station.adopt(loadSDK(), { apikey: APIKEY })

    equal('[station:taskpad]', pad.options().apikey)

    const result = await pad.Todo().list()
    ok(Array.isArray(result))

    const warns = station.events().filter((e) =>
      'station' === e.kind && /hoisted/.test(String(e.meta?.warn || '')))
    equal(1, warns.length)

    station.close()
  })

  test('a missing secret is station_secret_no_value on the op path', async () => {
    delete process.env.TASKPAD_APIKEY
    const station = Station.open({ config: null })
    const pad = station.connect(loadSDK())

    let thrown: any = null
    try { await pad.Todo().list() }
    catch (e: any) { thrown = e }
    ok(null != thrown, 'op failed')
    match(String(thrown.message), /station_secret_no_value/)

    const errs = station.events().filter((e) => 'error' === e.kind)
    equal(1, errs.length)
    equal('station_secret_no_value', errs[0].err!.code)

    station.close()
  })

  test('descriptor carries slug/version/target from the embedded config', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      station.connect(loadSDK())

      const d = station.descriptorOf('taskpad')
      equal('taskpad', d.slug)
      equal('TASKPAD', d.envtoken)
      equal('ts', d.target)
      equal('0.0.1', d.version)
      equal('taskpad.apikey', d.auth.secretname)
      deepEqual(Object.keys(d.entities), ['todo'])
      ok(d.entities.todo.ops.list)

      station.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })

  test('test feature stays mocked: no injection into mock transports', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      const station = Station.open({ config: null })
      const SDK = loadSDK()
      const pad = station.connect(SDK, {
        feature: { test: { active: true, entity: { todo: { t9: { id: 't9', title: 'mock' } } } } },
      })

      const got = (await pad.Todo().load({ id: 't9' })).data()
      equal('mock', got.title)

      // The http event saw the mock attempt; the placeholder was never
      // swapped (mode !== live), so no real value entered the mock store.
      const http = station.events().filter((e) => 'http' === e.kind)
      equal(1, http.length)

      station.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })
})
