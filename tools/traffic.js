#!/usr/bin/env node
'use strict'

// One process: the solardemo mock that tools/traffic.sh generated, a Station
// holding station-view and station-mcp, and the generated SDK bound to the
// mock. MCP is served on stdin and stdout, so everything else goes to stderr,
// or with --mcp-port over streamable HTTP, whose bearer token is
// STATION_MCP_TOKEN, else one it makes and prints.
//
//   node tools/traffic.js [--view-port <n>] [--mock-port <n>] [--mcp-port <n>] [--seed <s>] [--read-only]
//
// STATION_TRAFFIC_SDK names the generated project, else test/sdk/traffic-sdk;
// STATION_VIEW_HOME and STATION_MCP_HOME the extensions' checkouts, else
// siblings of this one.

const Path = require('node:path')

const ROOT = Path.resolve(__dirname, '..')
const SDK = Path.resolve(process.env.STATION_TRAFFIC_SDK || Path.join(ROOT, 'test', 'sdk', 'traffic-sdk'))
const VIEW = Path.resolve(process.env.STATION_VIEW_HOME || Path.join(ROOT, '..', 'station-view'))
const MCP = Path.resolve(process.env.STATION_MCP_HOME || Path.join(ROOT, '..', 'station-mcp'))

const USAGE = 'usage: traffic [--view-port <n>] [--mock-port <n>] [--mcp-port <n>] [--seed <s>] [--read-only]\n'

function parse(argv) {
  const args = { viewPort: 8960, mockPort: 0, seed: 1, write: true }
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    if ('--read-only' === flag) { args.write = false; continue }
    if (!['--view-port', '--mock-port', '--mcp-port', '--seed'].includes(flag)) {
      throw new Error('not understood: ' + flag)
    }
    const value = argv[++i]
    if (undefined === value) { throw new Error(flag + ' needs a value') }
    if ('--seed' === flag) { args.seed = value; continue }
    const port = /^\d+$/.test(value) && Number(value) <= 65535 ? Number(value) : undefined
    if (undefined === port) { throw new Error(flag + ' is not a port: ' + value) }
    if ('--view-port' === flag) { args.viewPort = port }
    else if ('--mcp-port' === flag) { args.mcpPort = port }
    else { args.mockPort = port }
  }
  return args
}

function load(where, what) {
  try {
    return require(where)
  }
  catch (err) {
    throw new Error('no ' + what + ' at ' + where + ': ' + err.message +
      ' (run make traffic first)')
  }
}

async function main() {
  const args = parse(process.argv.slice(2))

  const { Station } = load(Path.join(ROOT, 'typescript'), 'station typescript port')
  const { StationView } = load(Path.join(VIEW, 'typescript'), 'station-view')
  const { StationMcp } = load(Path.join(MCP, 'typescript'), 'station-mcp')
  const { makeMock } = load(Path.join(SDK, 'ts-mock'), 'generated mock')
  const { SolardemoSDK } = load(Path.join(SDK, 'ts'), 'generated SDK')

  const mock = await makeMock({ seed: args.seed }).listen(args.mockPort)
  // station-mcp opens a write tool only for an instance whose block sets
  // agent.write, as the proxy does, so the demo declares its instance.
  const config = {
    station: 1,
    profiles: { default: { sdk: { 'solardemo$demo': { agent: { write: args.write } } } } },
  }
  const st = Station.open({ config, proxy: 'off', load: false })
    .use(StationView)
    .use(StationMcp, { write: args.write })
  st.connect(SolardemoSDK, { instance: 'solardemo$demo', base: mock.url })

  const view = await st.extension('view/view').listen({ port: args.viewPort })
  const mcp = st.extension('mcp/mcp')
  const token = process.env.STATION_MCP_TOKEN
  const http = undefined === args.mcpPort ? undefined :
    await mcp.listen({ port: args.mcpPort, ...(token ? { token } : {}) })
  const stop = undefined === http ? mcp.serve({ input: process.stdin, output: process.stdout }) : http.close
  const where = undefined === http ? 'stdin and stdout' :
    http.url + ', bearer token ' + (token ? 'from STATION_MCP_TOKEN' : http.token)
  process.stderr.write('traffic: station-view on ' + view.url + '\n' +
    'traffic: solardemo mock on ' + mock.url + '\n' +
    'traffic: MCP on ' + where + (args.write ? '' : ', read only') + '\n')

  let closing = false
  const close = async () => {
    if (closing) { return }
    closing = true
    await stop()
    process.stdin.destroy()
    await view.close()
    await mock.close()
    st.close()
  }
  if (undefined === http) { process.stdin.once('end', close) }
  process.once('SIGINT', close)
  process.once('SIGTERM', close)
}

main().catch((err) => {
  process.stderr.write('traffic: ' + String(err && err.message || err) + '\n' + USAGE)
  process.exitCode = 1
})
