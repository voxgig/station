/* C4 (plugin/doc/plan/contracts.md, rows C4a/C4b): station runs
 * voxgig/plugin's corpus against its OWN implementation and reports
 * divergence as a plugin issue rather than absorbing it.
 *
 * This file is the corpus-side half of that harness: locating the
 * plugin checkout, loading spec/plugin.json, and the entry-judging
 * helpers PORTED from plugin/typescript/test/corpus.ts - they are the
 * definition of how an entry is judged, so they are ported rather than
 * approximated. The one deliberate departure: `check` takes a CODE
 * TABLE, because station raises its own §14 codes where plugin raises
 * §12 ones, and the mapping between them must be explicit and pinned
 * rather than implied by a regex. */

import * as Fs from 'node:fs'
import * as Path from 'node:path'

// ---------------------------------------------------------------------
// Locating the plugin checkout (same convention as src/omnihome.ts:
// env var first, then the places a sibling checkout usually sits).
// ---------------------------------------------------------------------

/** The plugin checkout, or null when none is present. Callers decide
 * what absence means: the suite skips cleanly by default, and fails
 * loudly when STATION_REQUIRE_C4 is set (CI sets it - a missing
 * checkout there is a broken lane, not an optional extra). */
export function pluginhome(): string | null {
  // __dirname at runtime is <station>/typescript/dist/test/c4.
  const candidates = [
    process.env.PLUGIN_HOME,
    Path.join(__dirname, '..', '..', '..', '..', 'plugin'),
    Path.join(__dirname, '..', '..', '..', '..', '..', 'plugin'),
    '/workspace/plugin',
    '/home/user/plugin',
  ]
  for (const candidate of candidates) {
    if (candidate && Fs.existsSync(Path.join(candidate, 'spec', 'plugin.json'))) {
      return Path.resolve(candidate)
    }
  }
  return null
}

// ---------------------------------------------------------------------
// The corpus, exactly as plugin's own runner reads it
// ---------------------------------------------------------------------

export type Entry = {
  id?: string
  doc?: boolean
  in?: any
  args?: any[]
  ctx?: any
  cmd?: any[]
  out?: any
  err?: boolean | string
  match?: any
  client?: string
}

export function corpus(home: string): any {
  return JSON.parse(
    Fs.readFileSync(Path.join(home, 'spec', 'plugin.json'), 'utf8'))
}

export function section(home: string, name: string): { [group: string]: Entry[] } {
  const spec = corpus(home)
  const sec = spec.primary && spec.primary[name]
  if (null == sec) { throw new Error('no such corpus section: ' + name) }
  const out: { [group: string]: Entry[] } = {}
  for (const g of Object.keys(sec)) {
    if ('DEF' === g) { continue }
    if (sec[g] && Array.isArray(sec[g].set)) { out[g] = sec[g].set }
  }
  return out
}

/** A stable label, so a failure (and a manifest row) names the entry.
 * Anonymous entries get `<section>/<group>@<index>` - `@` rather than
 * `#`, so a generated label can never collide with a corpus id (ids use
 * `#`, e.g. `config/optladder#1` sits beside anonymous entry index 1). */
export function label(sec: string, group: string, i: number, e: Entry): string {
  return e.id ? e.id : sec + '/' + group + '@' + i
}

// ---------------------------------------------------------------------
// equal / matches - ported verbatim from plugin's corpus.ts
// ---------------------------------------------------------------------

/** Deep equality over spec values. Key order never matters; list order
 * always does. */
export function equal(a: any, b: any): boolean {
  if (a === b) { return true }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) { return false }
    for (let i = 0; i < a.length; i++) { if (!equal(a[i], b[i])) { return false } }
    return true
  }
  if (isMap(a) && isMap(b)) {
    const ka = Object.keys(a).sort()
    const kb = Object.keys(b).sort()
    if (ka.length !== kb.length) { return false }
    for (let i = 0; i < ka.length; i++) { if (ka[i] !== kb[i]) { return false } }
    for (const k of ka) { if (!equal(a[k], b[k])) { return false } }
    return true
  }
  return false
}

/** Partial match: every key the expectation names must agree, and keys
 * it does not name are ignored. */
export function matches(expect: any, actual: any): boolean {
  if ('__EXISTS__' === expect) { return undefined !== actual }
  if ('__UNDEF__' === expect) { return undefined === actual }
  if ('__NULL__' === expect) { return null === actual }

  if ('string' === typeof expect && 2 < expect.length &&
    expect.startsWith('/') && expect.endsWith('/')) {
    if ('string' !== typeof actual) { return false }
    return new RegExp(expect.substring(1, expect.length - 1)).test(actual)
  }

  if (Array.isArray(expect)) {
    if (!Array.isArray(actual) || expect.length !== actual.length) { return false }
    for (let i = 0; i < expect.length; i++) {
      if (!matches(expect[i], actual[i])) { return false }
    }
    return true
  }

  if (isMap(expect)) {
    if (!isMap(actual)) { return false }
    for (const k of Object.keys(expect)) {
      if (!matches(expect[k], actual[k])) { return false }
    }
    return true
  }

  return expect === actual
}

export function isMap(v: any): boolean {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}

// ---------------------------------------------------------------------
// check - ported from plugin's corpus.ts, plus the explicit code table
// ---------------------------------------------------------------------

/** Expected plugin error code -> the station code that stands for it.
 * Part of the harness, visible and pinned: a raise still compares BY
 * CODE (plugin DOCS.md §4.6), the table only says which station code a
 * plugin code translates to. A plugin code with no row compares
 * untranslated - and therefore never matches a StationError, which is
 * exactly right for a case station does not raise at all. */
export type CodeMap = { [pluginCode: string]: string }

/** Run one entry against a subject and report the disagreement, if
 * any. Same three-combination rule as plugin's runner. */
export function check(
  e: Entry, subject: (e: Entry) => any, codemap: CodeMap
): string | null {
  if (undefined !== e.err && undefined !== e.out) {
    return 'entry has both err and out'
  }

  let value: any
  let raised: any = null
  try {
    value = subject(e)
  }
  catch (err: any) {
    raised = err
  }

  if (undefined !== e.err) {
    if (null == raised) { return 'expected a raise, got: ' + JSON.stringify(value) }
    if ('string' === typeof e.err) {
      const want = codemap[e.err] || e.err
      if (raised.code !== want) {
        return 'expected code ' + want + ' (for plugin ' + e.err + '), got ' +
          raised.code + ' (' + raised.message + ')'
      }
    }
    if (undefined !== e.match) {
      const got = { err: { code: raised.code, message: raised.message, name: raised.name } }
      if (!matches(xmatcherr(e.match, codemap), got)) {
        return 'error did not match ' + JSON.stringify(e.match) +
          ', got ' + JSON.stringify(got)
      }
    }
    return null
  }

  if (null != raised) {
    return 'unexpected raise: ' + (raised.code || '') + ' ' + raised.message
  }

  if (undefined !== e.out) {
    if (!equal(e.out, value)) {
      return 'expected ' + JSON.stringify(e.out) + ', got ' + JSON.stringify(value)
    }
  }

  if (undefined !== e.match) {
    if (!matches(e.match, { in: e.in, out: value })) {
      return 'did not match ' + JSON.stringify(e.match) +
        ', got out=' + JSON.stringify(value)
    }
  }

  if (undefined === e.out && undefined === e.match) {
    return 'entry asserts nothing'
  }

  return null
}

/** An err-entry's `match` may pin the code too; translate it through
 * the same table the code comparison uses, so the two cannot drift. */
function xmatcherr(match: any, codemap: CodeMap): any {
  if (!isMap(match) || !isMap(match.err)) { return match }
  const code = match.err.code
  if ('string' !== typeof code || !codemap[code]) { return match }
  return { ...match, err: { ...match.err, code: codemap[code] } }
}

/** Raised by the adapters when an entry reaches for vocabulary the
 * joint agreement gives no station counterpart for. Every entry that
 * can raise this belongs in the skip manifest; one that is NOT skipped
 * surfaces as an unexpected raise and fails the run - the guard that
 * keeps the manifest honest rather than merely decorative. */
export class NoCounterpart extends Error {
  constructor(what: string) {
    super('no station counterpart: ' + what)
    this.name = 'NoCounterpart'
  }
}
