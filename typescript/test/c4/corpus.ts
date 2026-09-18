
import * as Fs from 'node:fs'
import * as Path from 'node:path'

// ---------------------------------------------------------------------
// Locating the plugin checkout (same convention as src/omnihome.ts:
// env var first, then the places a sibling checkout usually sits).
// ---------------------------------------------------------------------

export function pluginhome(): string | null {
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


export type CodeMap = { [pluginCode: string]: string }

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
