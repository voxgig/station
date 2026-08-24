// The secret broker (design §5): sekreto resolves, station places. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.

const { Sekreto, SekretoError } = require('@voxgig/sekreto-js')

const { StationError } = require('./error')

// §7.2: keyed by INSTANCE. Two live instances of one api must have
// distinct placeholders or the injection seam cannot tell which
// credential a header wants. For an untagged instance this is the api
// slug, so the single-instance case is unchanged.
function placeholderFor(slug) {
  return '[station:' + slug + ']'
}

class SecretBroker {
  constructor(providers) {
    this.sekreto = new Sekreto({ providers })
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
  // length. sekreto's own redact() runs too, covering values resolved
  // by the underlying instance that station never held.
  scrub(text) {
    let out = this.sekreto.redact(text)
    for (const value of this.held) {
      if ('' !== value) {
        out = out.split(value).join('[redacted]')
      }
    }
    return out
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
  placeholderFor,
}
