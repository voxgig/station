'use strict'

// Drives tools/traffic.js over MCP, as a client would, and reads what the
// tools did back from station-view. Needs the SDK tools/traffic.sh
// generates: a missing one fails, it does not skip.

const { test } = require('node:test')
const Assert = require('node:assert')
const Fs = require('node:fs')
const Path = require('node:path')
const { spawn } = require('node:child_process')

const ROOT = Path.resolve(__dirname, '..')
const SDK = Path.resolve(process.env.STATION_TRAFFIC_SDK || Path.join(ROOT, 'test', 'sdk', 'traffic-sdk'))

// A test's own timeout leaves its awaits pending and its finally unrun, so
// every wait on the child is bounded here instead.
function bounded(promise, what, ms = 20000) {
  let timer
  const late = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(what + ' took more than ' + ms + ' ms')), ms)
  })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}

function start(args) {
  if (!Fs.existsSync(Path.join(SDK, 'ts-mock', 'dist', 'index.js'))) {
    throw new Error('no traffic SDK at ' + SDK + ': run make traffic')
  }
  const child = spawn(process.execPath, [Path.join(__dirname, 'traffic.js'), '--view-port', '0', ...args],
    { env: { ...process.env, STATION_TRAFFIC_SDK: SDK }, stdio: ['pipe', 'pipe', 'pipe'] })
  const waiting = new Map()
  let stderr = ''
  let buffered = ''
  let id = 0

  child.stderr.on('data', (chunk) => { stderr += chunk })
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    for (let nl = buffered.indexOf('\n'); -1 !== nl; nl = buffered.indexOf('\n')) {
      const line = buffered.slice(0, nl)
      buffered = buffered.slice(nl + 1)
      if ('' === line.trim()) { continue }
      const msg = JSON.parse(line)
      const answer = waiting.get(msg.id)
      if (undefined !== answer) {
        waiting.delete(msg.id)
        answer(msg)
      }
    }
  })
  const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)))

  return {
    exited,
    view: () => bounded(new Promise((resolve, reject) => {
      const timer = setInterval(() => {
        const found = /station-view on (\S+)/.exec(stderr)
        if (null != found) { clearInterval(timer); resolve(found[1]) }
      }, 20)
      exited.then((code) => { clearInterval(timer); reject(new Error('traffic exited ' + code + ': ' + stderr)) })
    }), 'starting'),
    rpc: (method, params) => bounded(new Promise((resolve) => {
      const n = ++id
      waiting.set(n, resolve)
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: n, method, params }) + '\n')
    }), method),
    notify: (method) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n'),
    call: async function (name, args) {
      const msg = await this.rpc('tools/call', { name, arguments: args })
      return { isError: true === msg.result.isError, value: JSON.parse(msg.result.content[0].text) }
    },
    end: () => { child.stdin.end(); return bounded(exited, 'exiting when stdin ends') },
    stop: () => { child.kill('SIGTERM'); return bounded(exited, 'exiting on SIGTERM') },
    kill: () => child.kill('SIGKILL'),
  }
}

async function records(view, query) {
  const res = await fetch(view + 'api/records?' + new URLSearchParams(query))
  Assert.strictEqual(res.status, 200)
  return res.json()
}

test('a tool called over MCP reaches the mock, and the view shows the call', { timeout: 60000 }, async () => {
  const traffic = start([])
  try {
    const view = await traffic.view()
    const init = await traffic.rpc('initialize',
      { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'traffic-test', version: '0' } })
    Assert.strictEqual(init.result.serverInfo.name, 'station-mcp')
    traffic.notify('notifications/initialized')

    const names = (await traffic.rpc('tools/list', {})).result.tools.map((t) => t.name)
    for (const name of ['solardemo_demo_list', 'solardemo_demo_load', 'solardemo_demo_create']) {
      Assert.ok(names.includes(name), name + ' in ' + names.join(' '))
    }

    const listed = await traffic.call('solardemo_demo_list', { entity: 'planet' })
    Assert.strictEqual(listed.isError, false)
    Assert.ok(0 < listed.value.length)
    Assert.ok(listed.value.every((p) => /^planet-\d+$/.test(p.id)), JSON.stringify(listed.value))

    const loaded = await traffic.call('solardemo_demo_load', { entity: 'planet', query: { id: listed.value[0].id } })
    Assert.deepStrictEqual(loaded.value, listed.value[0])

    const made = await traffic.call('solardemo_demo_create',
      { entity: 'planet', data: { name: 'Vulcan', kind: 'rare', diameter: 1200 } })
    Assert.strictEqual(made.value.name, 'Vulcan')
    Assert.ok(!listed.value.some((p) => p.id === made.value.id), 'a new id: ' + made.value.id)

    const missing = await traffic.call('solardemo_demo_load', { entity: 'planet', query: { id: 'planet-9999' } })
    Assert.strictEqual(missing.isError, true)

    const sent = (await records(view, { source: 'station' })).filter((r) => 'http' === r.kind)
    Assert.deepStrictEqual(sent.map((r) => [r.method, r.path, r.status]), [
      ['GET', '/api/planet', 200],
      ['GET', '/api/planet/' + listed.value[0].id, 200],
      ['POST', '/api/planet', 201],
      ['GET', '/api/planet/planet-9999', 404],
    ])

    const calls = await records(view, { source: 'debug' })
    Assert.deepStrictEqual(calls.map((r) => [r.op, r.method, r.status]), [
      ['planet.list', 'GET', 200],
      ['planet.load', 'GET', 200],
      ['planet.create', 'POST', 201],
      ['planet.load', 'GET', 404],
    ])
    Assert.deepStrictEqual(calls.map((r) => r.sdk), Array(4).fill('solardemo$demo'))

    for (const source of ['telemetry', 'audit']) {
      Assert.deepStrictEqual((await records(view, { source })).map((r) => [r.op, r.ok]),
        [['planet.list', true], ['planet.load', true], ['planet.create', true], ['planet.load', false]],
        source)
    }
    Assert.deepStrictEqual((await records(view, { source: 'station', op: 'planet.create' })).map((r) => r.ok), [true])
    Assert.strictEqual((await records(view, { status: 'failed', source: 'debug' })).length, 1)

    const sdks = await (await fetch(view + 'api/sdks')).json()
    Assert.strictEqual(sdks[0].name, 'solardemo$demo')
    Assert.strictEqual(sdks[0].metrics.total.count, 4)

    Assert.strictEqual(await traffic.end(), 0)
  }
  finally {
    traffic.kill()
  }
})

test('--read-only leaves the write tools out', { timeout: 60000 }, async () => {
  const traffic = start(['--read-only'])
  try {
    await traffic.view()
    await traffic.rpc('initialize',
      { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'traffic-test', version: '0' } })
    const names = (await traffic.rpc('tools/list', {})).result.tools.map((t) => t.name)
    Assert.ok(names.includes('solardemo_demo_list'))
    Assert.deepStrictEqual(names.filter((n) => /_(create|update|patch|remove)$/.test(n)), [])
    Assert.strictEqual(await traffic.stop(), 0)
  }
  finally {
    traffic.kill()
  }
})

test('the agent tools answer in process, from this checkout\'s Station', { timeout: 60000 }, async () => {
  const traffic = start([])
  try {
    await traffic.view()
    await traffic.rpc('initialize',
      { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'traffic-test', version: '0' } })
    await traffic.call('solardemo_demo_list', { entity: 'planet' })

    const described = await traffic.call('station_describe', { plugin: 'solardemo$demo' })
    Assert.strictEqual(described.isError, false, JSON.stringify(described.value))
    Assert.ok(described.value.entities.planet.ops.includes('list'), JSON.stringify(described.value))

    const events = await traffic.call('station_traffic', { plugin: 'solardemo$demo', grep: 'planet' })
    Assert.strictEqual(events.isError, false, JSON.stringify(events.value))
    Assert.ok(0 < events.value.events.length, JSON.stringify(events.value))

    const policy = await traffic.call('station_policy', { plugin: 'solardemo$demo' })
    Assert.deepStrictEqual([policy.value.agentWrite, policy.value.writeTools], [true, true])

    const secrets = await traffic.call('station_secrets', {})
    Assert.strictEqual(secrets.isError, false, JSON.stringify(secrets.value))
    Assert.deepStrictEqual(secrets.value.secrets.map((r) => r.plugin), ['solardemo$demo'])

    Assert.strictEqual(await traffic.end(), 0)
  }
  finally {
    traffic.kill()
  }
})
