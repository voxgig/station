
import { test } from 'node:test'
import * as Assert from 'node:assert'

import { Station } from '../src/Station'

function station(): Station {
  return new Station({ config: null, proxy: 'off', load: false })
}

test('use takes an extension live, and it reads the station', () => {
  const st = station()
  let seen: any
  st.use({
    name: 'probe',
    activate(inst: any) {
      seen = inst.host().exports('station/station')
      inst.export('probe', { mode: seen.status().mode, options: inst.options })
    },
  }, { colour: 'blue' })

  Assert.strictEqual(seen, st)
  Assert.deepStrictEqual(st.extensions(), [{ name: 'probe', status: 'live' }])
  Assert.deepStrictEqual(st.extension('probe/probe'), { mode: 'solo', options: { colour: 'blue' } })
  st.close()
})

test('close takes every extension down, and leaves none listed', () => {
  const st = station()
  const log: string[] = []
  for (const name of ['alpha', 'zeta']) {
    st.use({
      name,
      activate(inst: any) { inst.release(() => log.push('release ' + name)) },
      close() { log.push('close ' + name) },
    })
  }

  st.close()
  Assert.deepStrictEqual(log.sort(), ['close alpha', 'close zeta', 'release alpha', 'release zeta'])
  Assert.deepStrictEqual(st.extensions(), [])
})

test('a station that is never extended lists none', () => {
  const st = station()
  Assert.deepStrictEqual(st.extensions(), [])
  Assert.strictEqual(st.extension('view/view'), undefined)
  st.close()
})

test('an extension may not take the name station', () => {
  const st = station()
  Assert.throws(() => st.use({ name: 'station' }),
    (err: any) => 'plugin_ref_reserved' === err.code)
  st.close()
})

test('use is idempotent for one definition, and refuses another under its name', () => {
  const st = station()
  let activations = 0
  const def = { name: 'once', activate() { activations++ } }
  st.use(def).use(def)
  Assert.strictEqual(activations, 1)
  Assert.throws(() => st.use({ name: 'once' }),
    (err: any) => 'plugin_ref_duplicate' === err.code)
  st.close()
})

test('a closed station takes no extension', () => {
  const st = station()
  st.close()
  Assert.throws(() => st.use({ name: 'late' }),
    (err: any) => 'station_no_plugin' === err.code && /station is closed/.test(err.message))
  Assert.deepStrictEqual(st.extensions(), [])
})

test('a name Object.prototype holds is refused as a bad name, before the host sees it', () => {
  const st = station()
  for (const name of ['constructor', 'toString', 'hasOwnProperty']) {
    Assert.throws(() => st.use({ name }), (err: any) => 'plugin_bad_name' === err.code, name)
  }
  Assert.deepStrictEqual(st.extensions(), [])
  st.use({ name: 'tostring' })
  Assert.deepStrictEqual(st.extensions(), [{ name: 'tostring', status: 'live' }])
  st.close()
})

test('an extension that fails to activate raises and is listed failed', () => {
  const st = station()
  Assert.throws(() => st.use({ name: 'broken', activate() { throw new Error('no') } }),
    (err: any) => 'plugin_activate_failed' === err.code)
  Assert.deepStrictEqual(st.extensions(), [{ name: 'broken', status: 'failed' }])
  st.close()
})

test('extensions are not plugins: plugins() and status() list bound SDKs only', () => {
  const st = station()
  st.use({ name: 'probe' })
  Assert.deepStrictEqual(st.plugins(), [])
  Assert.deepStrictEqual(st.status().plugins, [])
  st.close()
})
