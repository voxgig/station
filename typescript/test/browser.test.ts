// RUN: npm test
//
// The browser entry (design §2.2, §17 Phase 1): `index.browser.ts` must
// expose everything EXCEPT the file-loading half, and its module graph
// must pull no `node:` builtin - "no unconditional node: imports for
// the file provider, token file, or socket probe". Bundlers consume the
// ts package for browsers today, so this is checked as a resolver walk
// over the COMPILED dist files: the same requires a bundler follows.
//
// The boundary stated honestly: the walk covers THIS package's modules.
// External dependencies (@voxgig/sekreto, @voxgig/struct) are recorded
// but not entered - sekreto's own browser posture is sekreto's work,
// and §2.2 scopes this item to station's entry points.

import { describe, test } from 'node:test'
import { deepStrictEqual, equal, ok } from 'node:assert'

import * as Fs from 'node:fs'
import * as Path from 'node:path'
import { builtinModules } from 'node:module'

import * as browser from '../src/index.browser'
import { provide, resetFactories } from '../src/factory'

const DIST = Path.resolve(Path.join(__dirname, '..', 'src'))

// Every require() specifier in one compiled CJS module.
function requiresOf(file: string): string[] {
  const text = Fs.readFileSync(file, 'utf8')
  const out: string[] = []
  const re = /require\(\s*["']([^"']+)["']\s*\)/g
  let m: RegExpExecArray | null
  while (null != (m = re.exec(text))) { out.push(m[1]) }
  return out
}

// Walk the module graph from one compiled entry, following RELATIVE
// specifiers; return every module file reached and every non-relative
// specifier seen.
function walk(entry: string): { files: string[], external: string[] } {
  const seen = new Set<string>()
  const external = new Set<string>()
  const todo = [Path.resolve(DIST, entry)]
  while (0 < todo.length) {
    const file = todo.pop()!
    if (seen.has(file)) { continue }
    seen.add(file)
    for (const spec of requiresOf(file)) {
      if (spec.startsWith('.')) {
        let next = Path.resolve(Path.dirname(file), spec)
        if (!next.endsWith('.js')) { next = next + '.js' }
        todo.push(next)
      }
      else {
        external.add(spec)
      }
    }
  }
  return { files: Array.from(seen).sort(), external: Array.from(external).sort() }
}

function isbuiltin(spec: string): boolean {
  return spec.startsWith('node:') || builtinModules.includes(spec)
}

describe('browser-entry', () => {

  test('the browser graph pulls no node: builtins', () => {
    const { files, external } = walk('index.browser.js')

    deepStrictEqual(external.filter(isbuiltin), [],
      'the browser entry must not reach a node builtin')

    // ...and the graph is the real one, not a stub: the whole library
    // core is on it, while the node-only file half is not.
    const names = files.map((f) => Path.basename(f))
    ok(names.includes('Station.js'), 'Station rides the browser entry')
    ok(names.includes('shape.js'), 'validation rides the browser entry')
    ok(!names.includes('profile.js'),
      'profile.js is the node-only file half and must stay off the graph')
    ok(!names.includes('omnihome.js'),
      'omnihome.js is node-only test plumbing and must stay off the graph')
    ok(!names.includes('index.js'),
      'the node entry (which registers the file seam) must stay off the graph')
  })

  test('...and the walker has teeth: the node graph does pull them', () => {
    // The positive control. If the walker cannot see profile.js's
    // node:fs from the NODE entry, the browser assertion above is
    // vacuous.
    const { files, external } = walk('index.js')
    ok(0 < external.filter(isbuiltin).length,
      'the node entry reaches node builtins through profile.js')
    ok(files.map((f) => Path.basename(f)).includes('profile.js'))
  })

  test('the browser surface drops exactly the file-loading half', () => {
    const b: any = browser
    // Present: the library core.
    for (const name of ['Station', 'instanceRef', 'provide', 'StationError',
      'canonicalSerialize', 'normalizeConfig', 'validateConfig',
      'resolveProfile', 'selectProfile', 'refapi', 'featureBinding']) {
      equal('undefined' !== typeof b[name], true, name + ' is exported')
    }
    // Absent: the node-only file half (design §2.2 names the file
    // provider/config-file machinery as the node-only piece).
    for (const name of ['loadConfig', 'findConfigFile', 'configScope']) {
      equal(undefined, b[name], name + ' must not ride the browser entry')
    }
  })

  test('open() on the browser entry takes config as an object', () => {
    // The seam is UNREGISTERED in this process (nothing here imports
    // ../src/index), which IS the browser condition: no file loading
    // exists, and the explicit-config path carries everything.
    resetFactories()
    browser.Station.reset()

    // No config at all: exactly node's "no station.json found".
    const bare = browser.Station.open({})
    equal('solo', bare.status().mode)
    deepStrictEqual(bare.instances(), [])
    bare.close()
    browser.Station.reset()

    // Explicit config: the declarative front door, no file involved.
    const config: any = {
      main: { slug: 'solar', name: 'solar', version: '1.0.0' },
      options: { auth: { prefix: 'Bearer ' }, server: {} },
      entity: {},
    }
    class SDK {
      options: any
      _features = [{ name: 'station' }]
      _mode = 'test'
      constructor(options: any) {
        this.options = options
        const fopts = options?.feature?.station
        if (null != fopts) {
          browser.featureBinding({
            client: this,
            utility: { fetcher: async () => ({ status: 200 }) },
            options: { feature: {} },
            config,
          }, fopts)
        }
      }
    }
    provide('solar', { construct: (o: any) => new SDK(o), config })

    const st = new browser.Station({
      config: { station: 1, profiles: { default: { sdk: { solar: {} } } } },
    })
    const client: any = st.sdk('solar')
    ok(null != client)
    deepStrictEqual(st.plugins().map((p) => p.name), ['solar'])
    st.close()
    resetFactories()
  })
})
