import { test, describe, before, after } from 'node:test'
import { equal, deepEqual, ok } from 'node:assert'

import { spawn, ChildProcess } from 'node:child_process'
import * as Path from 'node:path'
import * as Fs from 'node:fs'

import { Station } from '../src/Station'

// An SDK generated without the station feature, as connect() and adopt()
// retrofit it, against a server whose first answer is a 503.
const SDK_ROOT = process.env.STATION_TEST_SDKS || '/home/user/voxgig-sdk'
const SDK_DIR = Path.join(SDK_ROOT, 'taskpad-plain-sdk', 'ts', 'dist')
const SERVER_JS = Path.join(__dirname, '..', '..', '..', 'test', 'api', 'taskpad', 'server.js')

const APIKEY = 'taskpad-key-101'
const PORT = 8941

const HAVE_SDK = Fs.existsSync(SDK_DIR)

let server: ChildProcess

before(async () => {
  if (!HAVE_SDK) { return }
  server = spawn('node', [SERVER_JS], {
    env: { ...process.env, TASKPAD_APIKEY: APIKEY, TASKPAD_PORT: String(PORT), TASKPAD_FAIL: '1' },
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  await new Promise<void>((resolve, reject) => {
    server.stdout!.on('data', () => resolve())
    server.on('error', reject)
    setTimeout(() => reject(new Error('taskpad server did not start')), 5000)
  })
})

after(() => { server?.kill() })

if (!HAVE_SDK && process.env.STATION_REQUIRE_SDKS) {
  test('generated SDKs required', () => {
    throw new Error('STATION_REQUIRE_SDKS is set but the generated SDKs are ' +
      'not under ' + SDK_ROOT + ' - run `make fixtures`')
  })
}

describe('retrofit', { skip: !HAVE_SDK }, () => {

  test('live, with retry: station wraps the wire and sees each attempt', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      Station.reset()
      const { TaskpadSDK } = require(Path.join(SDK_DIR, 'TaskpadSDK'))
      const station = Station.open({ config: null })
      const pad = station.connect(TaskpadSDK, {
        base: 'http://127.0.0.1:' + PORT,
        feature: { retry: { active: true } },
      })

      deepEqual(pad._features.map((f: any) => f.name), ['station', 'retry'])

      const todos = await pad.Todo().list()
      ok(0 < todos.length)

      const events = station.events().filter((e) => 'http' === e.kind || 'op' === e.kind)
      deepEqual(events.map((e) => [e.kind, e.http?.status ?? e.op?.outcome]),
        [['http', 503], ['http', 200], ['op', 'ok']])
      equal(1, new Set(events.map((e) => e.corr)).size)

      station.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })

  // sdkgen's ordered array form: position is init order, so station takes
  // its pinned place first rather than the caller's map spread.
  test('the array form of options.feature binds, with retry outside station', async () => {
    process.env.TASKPAD_APIKEY = APIKEY
    try {
      Station.reset()
      const { TaskpadSDK } = require(Path.join(SDK_DIR, 'TaskpadSDK'))
      const station = Station.open({ config: null })
      const pad = station.connect(TaskpadSDK, {
        base: 'http://127.0.0.1:' + PORT,
        feature: [{ name: 'retry', active: true }],
      })

      deepEqual(pad._features.map((f: any) => f.name), ['station', 'retry'])

      const todos = await pad.Todo().list()
      ok(0 < todos.length)

      const events = station.events().filter((e) => 'http' === e.kind || 'op' === e.kind)
      deepEqual(events.map((e) => [e.kind, e.http?.status ?? e.op?.outcome]).slice(-2),
        [['http', 200], ['op', 'ok']])

      station.close()
    }
    finally {
      delete process.env.TASKPAD_APIKEY
    }
  })
})
