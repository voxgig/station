
import { describe, test } from 'node:test'
import { equal, match, ok, rejects } from 'node:assert'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

import { nativeImport } from '../src/loader'

describe('esm-preload', () => {

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
