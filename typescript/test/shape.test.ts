
import { describe, test } from 'node:test'
import { deepStrictEqual, ok } from 'node:assert'

import Fs from 'node:fs'
import Path from 'node:path'

import { CONFIG_SHAPE } from '../src/config-shape'
import { BLOCK_DEFAULTS, MERGE_SENSITIVE, PROFILE_DEFAULTS } from '../src/shape'

const SPEC = Path.resolve(
  Path.join(__dirname, '..', '..', '..', 'spec', 'config-shape.json'))

describe('config-shape', () => {

  // package.json ships `dist/src` only, so validateConfig cannot read
  // `spec/` at runtime - it runs at open(), not just under test. The
  // mirror is the shipped copy and this is what keeps it honest.
  test('mirror matches the spec file', () => {
    const onDisk = JSON.parse(Fs.readFileSync(SPEC, 'utf8'))
    deepStrictEqual(CONFIG_SHAPE, onDisk,
      'src/config-shape.ts has drifted from spec/config-shape.json - ' +
      'edit the JSON and re-run `make sync-shape`')
  })

  test('the two block specs are identical', () => {
    const profile = CONFIG_SHAPE.profiles['`$CHILD`']
    deepStrictEqual(profile.api['`$CHILD`'], profile.sdk['`$CHILD`'],
      'the api and sdk block specs are one concept written twice as ' +
      'data; they must not drift')
  })

  // §4.2's timing rule, asserted rather than left to a comment. The
  // profile-level containers are safe to materialize early either way;
  // exactly one block key is not, and a port that gets this wrong looks
  // correct on every single-profile test.
  test('exactly one block default is merge-sensitive', () => {
    deepStrictEqual(MERGE_SENSITIVE, ['active'])
    for (const k of MERGE_SENSITIVE) {
      ok(k in BLOCK_DEFAULTS, k + ' is merge-sensitive but has no default')
    }
    for (const [name, table] of
      [['profile', PROFILE_DEFAULTS], ['block', BLOCK_DEFAULTS]] as any[]) {
      for (const k of Object.keys(table)) {
        const v = table[k]()
        const container = null != v && 'object' === typeof v
        ok(container || MERGE_SENSITIVE.includes(k),
          name + ' default `' + k + '` is a scalar but is not listed in ' +
          'MERGE_SENSITIVE - a scalar default synthesized before the ' +
          'profile merge overwrites the base\'s real value (§3.3)')
      }
    }
  })

  test('only the feature entries are open', () => {
    const open: string[] = []
    const walk = (node: any, path: string): void => {
      if (null == node || 'object' !== typeof node) { return }
      if (Array.isArray(node)) {
        node.forEach((v, i) => walk(v, path + '.' + i))
        return
      }
      if (true === node['`$OPEN`']) { open.push(path) }
      for (const k of Object.keys(node)) { walk(node[k], path + '.' + k) }
    }
    walk(CONFIG_SHAPE, '')
    deepStrictEqual(open.sort(), [
      '.profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`',
      '.profiles.`$CHILD`.feature.`$CHILD`',
      '.profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`',
    ])
  })
})
