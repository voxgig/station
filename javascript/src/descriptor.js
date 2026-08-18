// A port of typescript/src/descriptor.ts, which is canonical.

// The ONLY way to build an env-var token in station, mirroring sdkgen's
// packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
// `secretname` corpus section pins the round-trip against sekreto's
// envkey() and sdkgen's envName() - the one place three grammars meet.
function envtoken(name) {
  return String(name || '')
    .toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '')
}

// The default sekreto name for a plugin (design §5.1): envtoken(slug)
// lowercased, plus '.apikey'. sekreto's envkey() then yields exactly the
// env var the SDK's README documents: gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
function secretnameDefault(slug) {
  return envtoken(slug).toLowerCase() + '.apikey'
}

// Best-effort slug from a camel name, for SDKs whose embedded config
// predates main.slug (design §4 legacy sentinels). The hyphen caveat is
// real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT 'voxgig-solardemo' -
// callers surface a warning event when this path is taken.
function legacySlug(name) {
  return String(name || '').toLowerCase()
}

// Normalize a generated SDK's embedded config into descriptor v1
// (design §4). The config is the one every SDK carries (Config.main /
// .feature / .options / .entity); the descriptor is a VIEW over it.
// Returns the descriptor plus any legacy warnings.
function normalizeDescriptor(config, activeFeatures) {
  const warnings = []
  const main = config?.main || {}
  const options = config?.options || {}

  const name = String(main.name || '')
  let slug = main.slug
  if (null == slug || '' === slug) {
    slug = legacySlug(name)
    warnings.push('descriptor: legacy config has no main.slug; derived "' +
      slug + '" from the camel name - hyphens in the original name are lost')
  }

  const version = null != main.version ? String(main.version) : '0.0.0'
  const target = null != main.target ? String(main.target) : 'unknown'

  const server = []
  const svr = options.server || {}
  for (const k of Object.keys(svr).sort()) {
    server.push({ name: k, value: String(svr[k]) })
  }

  const authActive = null != options.auth
  const auth = {
    active: authActive,
    prefix: authActive ? String(options.auth.prefix || '') : '',
    secretname: secretnameDefault(slug),
  }

  const entities = {}
  const entdefs = config?.entity || {}
  for (const ename of Object.keys(entdefs).sort()) {
    const e = entdefs[ename] || {}
    const fields = {}
    for (const f of e.fields || []) {
      if (null != f && null != f.name) {
        fields[f.name] = { kind: String(f.kind || f.type || '') }
      }
    }
    const ops = {}
    const opdefs = e.op || {}
    for (const opname of Object.keys(opdefs).sort()) {
      const op = opdefs[opname] || {}
      const points = []
      for (const p of op.points || []) {
        if (null == p) { continue }
        const point = {
          method: String(p.method || ''),
          path: String(p.orig || p.path || ''),
          params: (p.parts || []).filter((s) => 'string' === typeof s &&
            s.startsWith(':')).map((s) => s.slice(1)),
        }
        if (null != p.select) { point.select = p.select }
        points.push(point)
      }
      ops[opname] = { points }
    }
    entities[ename] = { fields, ops }
  }

  const features = []
  const fdefs = config?.feature || {}
  const factive = activeFeatures || {}
  for (const fname of Object.keys(fdefs).sort()) {
    features.push({ name: fname, active: true === factive[fname]?.active })
  }

  const descriptor = {
    station: 1,
    name, slug,
    envtoken: envtoken(slug),
    version, target,
    base: String(options.base || ''),
    server, auth, entities, features,
  }

  return { descriptor, warnings }
}

// Canonical serialization (design §4): UTF-8, object keys sorted
// bytewise, no insignificant whitespace, minimal JSON escaping. The
// proxy dedupes registrations by a hash of this, so every language must
// produce identical bytes - the `canonical-serialize` corpus section
// carries the adversarial cases.
function canonicalSerialize(value) {
  if (null === value || 'boolean' === typeof value || 'number' === typeof value) {
    return JSON.stringify(value)
  }
  if ('string' === typeof value) {
    return JSON.stringify(value)
  }
  if (Array.isArray(value)) {
    return '[' + value.map(canonicalSerialize).join(',') + ']'
  }
  if ('object' === typeof value) {
    const keys = Object.keys(value).filter((k) => undefined !== value[k])
    // Bytewise sort: compare UTF-8 byte sequences, not UTF-16 code units.
    keys.sort((a, b) => {
      const ab = Buffer.from(a, 'utf8'), bb = Buffer.from(b, 'utf8')
      return Buffer.compare(ab, bb)
    })
    return '{' + keys.map((k) =>
      JSON.stringify(k) + ':' + canonicalSerialize(value[k])).join(',') + '}'
  }
  return 'null'
}

module.exports = {
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
}
