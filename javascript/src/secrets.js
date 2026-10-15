// The secret broker (design §5): sekreto resolves, station places. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.

const { Sekreto, SekretoError } = require('@voxgig/sekreto-js')
const { allplugins } = require('@voxgig/sekreto-js/plugins')

const { StationError } = require('./error')

// §7.2: keyed by INSTANCE. Two live instances of one api must have
// distinct placeholders or the injection seam cannot tell which
// credential a header wants. For an untagged instance this is the api
// slug, so the single-instance case is unchanged.
function placeholderFor(slug) {
  return '[station:' + slug + ']'
}

const UNRESERVED = /^[A-Za-z0-9\-._~]$/
const HEXPAIR = /^[0-9A-Fa-f]{2}$/

// Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
function encodeQueryValue(value) {
  let out = ''
  for (const byte of Buffer.from(value, 'utf8')) {
    const ch = String.fromCharCode(byte)
    out += byte < 0x80 && UNRESERVED.test(ch)
      ? ch
      : '%' + byte.toString(16).toUpperCase().padStart(2, '0')
  }
  return out
}

function matchAt(text, at, end, placeholder) {
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
function substitute(url, headers, placeholder, value) {
  const out = { ...(headers || {}) }
  if ('' === placeholder) { return { url, headers: out } }

  for (const h of Object.keys(out)) {
    const v = out[h]
    if ('string' === typeof v && v.includes(placeholder)) {
      out[h] = v.split(placeholder).join(value)
    }
  }

  const q = url.indexOf('?')
  const hash = url.indexOf('#')
  if (-1 === q || (-1 !== hash && hash < q)) { return { url, headers: out } }
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

// Every form of every value is matched against the original text and the
// union of the matches redacted, so no replacement can hide another form.
function redactValues(text, values) {
  const forms = new Set()
  for (const value of values) {
    if ('' !== value) {
      forms.add(value)
      forms.add(encodeQueryValue(value))
    }
  }
  const reach = (at) => {
    let end = at
    for (const form of forms) {
      if (at + form.length > end && text.startsWith(form, at)) { end = at + form.length }
    }
    return end
  }

  let out = ''
  for (let i = 0; i < text.length;) {
    let stop = reach(i)
    if (stop === i) {
      out += text[i++]
      continue
    }
    for (let j = i + 1; j < stop; j++) {
      stop = Math.max(stop, reach(j))
    }
    out += '[redacted]'
    i = stop
  }
  return out
}

class SecretBroker {
  constructor(providers) {
    // allplugins, because a control surface does not get to choose the
    // chain: the profile does, at run time, and station must honour any
    // kind a station.json names. sekreto moved its provider kinds onto
    // voxgig/plugin (sekreto 43eb579), leaving only dotenv/env/file/memory
    // built in, so without this a profile naming `hashicorp` - or
    // `minivault` - fails at open() with "unknown provider kind". This is
    // the case sekreto's own plugins entry documents as its reason to
    // exist.
    this.sekreto = new Sekreto({ plugins: allplugins, providers })
    // Values hoisted by adopt() from resident options.apikey (design §3.1).
    this.overrides = new Map()
    this.cache = new Map()
    // Every value this broker ever held, for the exact-value scrub.
    this.held = []
  }

  hoist(slug, value) {
    this.overrides.set(slug, value)
    this.held.push(value)
  }

  // Resolve the value for a plugin's secret name. Misses and store
  // errors keep sekreto's distinction (design §5.2): a miss is
  // station_secret_no_value, a store that could not answer is
  // station_secret_error with sekreto's message intact - and never a
  // retry against a weaker store (sekreto owns the chain).
  // OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
  // SECRET NAME (§5.3). A hoisted credential belongs to the one instance
  // it was resident in, but a resolved VALUE belongs to the name it was
  // resolved for - so several instances sharing one api-level `secret`
  // cost one lookup rather than one each, and every client an
  // auto-tagged `create()` produces shares the declared instance's entry
  // instead of re-resolving per request.
  //
  // Keying the cache by instance instead is the defect this replaces: at
  // 26 instances over 20 apis it turns one store round-trip into 26.
  async value(slug, name) {
    const override = this.overrides.get(slug)
    if (null != override) { return override }

    const cached = this.cache.get(name)
    if (null != cached) { return cached }

    let value
    try {
      value = await this.sekreto.get(name)
    }
    catch (e) {
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

  // Exact-value scrub, deliberately WITHOUT sekreto's four-character
  // readability floor (design §7 as revised): on boundaries where the
  // promise is absolute, every held value is scrubbed whatever its
  // length. sekreto's own redact() runs after, covering values resolved
  // by the underlying instance that station never held; run first, its
  // raw-value replacement could split an encoded form.
  scrub(text) {
    const raw = 'string' === typeof text ? text : ''
    return this.sekreto.redact(redactValues(raw, this.held))
  }

  // Drop caches so the next resolve asks the stores again (rotation
  // support rides on sekreto's refresh, design §5.3).
  refresh() {
    this.cache.clear()
    if ('function' === typeof this.sekreto.refresh) {
      this.sekreto.refresh()
    }
  }
}

module.exports = {
  SecretBroker,
  encodeQueryValue,
  placeholderFor,
  substitute,
}
