// RUN: npm test
//
// THE DEFECT WAS IN THE EMIT, WHICH IS WHY THIS TEST EXISTS AT ALL.
//
// The package compiles with `module: "commonjs"`, and TypeScript
// rewrites a literal `import(pkg)` into a promise around `require(pkg)`.
// So `await station.load()` — the preload whose entire purpose is
// ESM-only packages — threw `ERR_REQUIRE_ESM` for exactly those. Nothing
// in the source read wrong; `dist/src/loader.js` read `mod =
// require(pkg)`.
//
// The suite runs against `dist`, so this reproduces the real emit rather
// than the source's intent.

import { describe, test } from 'node:test'
import { equal, match, ok, rejects } from 'node:assert'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

import { nativeImport } from '../src/loader'

describe('esm-preload', () => {

  // AN ESM MODULE WITH TOP-LEVEL AWAIT, and the choice is the test.
  //
  // My first version used a plain `.mjs` and asserted `require` fails on
  // it. On Node 22 it does not: `require(esm)` landed for synchronous
  // module graphs, so the assertion was false and the test told me so.
  // An ASYNC module is the case no Node version can require, which
  // makes it the one that actually separates a native import from a
  // downlevelled one.
  const asyncEsm = (): string => {
    const dir = mkdtempSync(join(tmpdir(), 'station-esm-'))
    const file = join(dir, 'tla.mjs')
    writeFileSync(file,
      'await Promise.resolve()\n' +
      'export const config = { main: { slug: "tla" } }\n')
    return file
  }

  test('the async seam is a NATIVE import, not require', async () => {
    const mod = await nativeImport(pathToFileURL(asyncEsm()).href)
    equal('tla', mod.config.main.slug)
  })

  test('...and `require` on that same module is what it replaced', () => {
    // Without this half the test above would pass on a downlevelled
    // `require` for anything Node happens to be able to require, which
    // is how the original defect stayed invisible.
    let code = ''
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      require(asyncEsm())
    }
    catch (e: any) { code = String(e?.code || e?.message || '') }

    ok('' !== code, 'require must fail on an async ESM module')
    match(code, /ERR_REQUIRE_ASYNC_MODULE|ERR_REQUIRE_ESM/)
  })
})
