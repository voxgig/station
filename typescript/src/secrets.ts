import { Sekreto, SekretoError } from '@voxgig/sekreto'
import { allplugins } from '@voxgig/sekreto/plugins'

import { StationError } from './error'

// The secret broker (design §5): sekreto resolves, station places. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.

export function placeholderFor(slug: string): string {
  return '[station:' + slug + ']'
}

const UNRESERVED = /^[A-Za-z0-9\-._~]$/
const HEXPAIR = /^[0-9A-Fa-f]{2}$/

// Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
export function encodeQueryValue(value: string): string {
  let out = ''
  for (const byte of Buffer.from(value, 'utf8')) {
    const ch = String.fromCharCode(byte)
    out += byte < 0x80 && UNRESERVED.test(ch)
      ? ch
      : '%' + byte.toString(16).toUpperCase().padStart(2, '0')
  }
  return out
}

function matchAt(text: string, at: number, end: number, placeholder: string): number {
  let i = at
  for (const ch of placeholder) {
    if (i < end && text[i] === ch) { i++; continue }
    const hex = text.substring(i + 1, i + 3)
    if (i + 3 <= end && '%' === text[i] && HEXPAIR.test(hex) &&
      parseInt(hex, 16) === ch.charCodeAt(0)) {
      i += 3
      continue
    }
    return -1
  }
  return i - at
}

// The placeholder becomes the value in header values and in the URL query,
// where an SDK percent-encodes it (any hex case) and the value is encoded in
// turn. The path and fragment are never touched; the headers are a copy.
export function substitute(url: string, headers: Record<string, any> | null | undefined,
  placeholder: string, value: string): { url: string, headers: Record<string, any> } {
  const out: Record<string, any> = { ...(headers || {}) }
  if ('' === placeholder) { return { url, headers: out } }

  for (const h of Object.keys(out)) {
    const v = out[h]
    if ('string' === typeof v && v.includes(placeholder)) {
      out[h] = v.split(placeholder).join(value)
    }
  }

  const q = url.indexOf('?')
  if (-1 === q) { return { url, headers: out } }
  const hash = url.indexOf('#', q)
  const end = -1 === hash ? url.length : hash
  const encoded = encodeQueryValue(value)
  let query = ''
  for (let i = q + 1; i < end;) {
    const n = matchAt(url, i, end, placeholder)
    if (0 < n) {
      query += encoded
      i += n
    }
    else {
      query += url[i]
      i++
    }
  }
  return { url: url.substring(0, q + 1) + query + url.substring(end), headers: out }
}

export class SecretBroker {
  private sekreto: Sekreto
  // Values hoisted by adopt() from resident options.apikey (design §3.1).
  private overrides = new Map<string, string>()
  private cache = new Map<string, string>()
  // Every value this broker ever held, for the exact-value scrub.
  private held: string[] = []

  constructor(providers: any[]) {
    this.sekreto = new Sekreto({ plugins: allplugins, providers })
  }

  hoist(slug: string, value: string): void {
    this.overrides.set(slug, value)
    this.held.push(value)
  }

  async value(slug: string, name: string): Promise<string> {
    const override = this.overrides.get(slug)
    if (null != override) { return override }

    const cached = this.cache.get(name)
    if (null != cached) { return cached }

    let value: string
    try {
      value = await this.sekreto.get(name)
    }
    catch (e: any) {
      if (e instanceof SekretoError && e.message.includes('unknown secret')) {
        throw new StationError('station_secret_no_value',
          'no store had "' + name + '" for plugin "' + slug + '"')
      }
      throw new StationError('station_secret_error', String(e?.message || e))
    }

    this.cache.set(name, value)
    this.held.push(value)
    return value
  }

  scrub(text: string): string {
    let out = this.sekreto.redact(text)
    for (const value of this.held) {
      if ('' !== value) {
        out = out.split(value).join('[redacted]')
        const encoded = encodeQueryValue(value)
        if (encoded !== value) {
          out = out.split(encoded).join('[redacted]')
        }
      }
    }
    return out
  }

  // Drop caches so the next resolve asks the stores again (rotation
  // support rides on sekreto's refresh, design §5.3).
  refresh(): void {
    this.cache.clear()
    if ('function' === typeof (this.sekreto as any).refresh) {
      ;(this.sekreto as any).refresh()
    }
  }
}
