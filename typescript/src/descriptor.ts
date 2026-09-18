import { Descriptor, DescriptorEntity, DescriptorPoint } from './types'

export function envtoken(name: any): string {
  return String(name || '')
    .toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '')
}

// The default sekreto name for a plugin (design §5.1): envtoken(slug)
// lowercased, plus '.apikey'. sekreto's envkey() then yields exactly the
// env var the SDK's README documents: gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
export function secretnameDefault(slug: string): string {
  return envtoken(slug).toLowerCase() + '.apikey'
}

function legacySlug(name: string): string {
  return String(name || '').toLowerCase()
}

// Normalize a generated SDK's embedded config into descriptor v1
// (design §4). The config is the one every SDK carries (Config.main /
// .feature / .options / .entity); the descriptor is a VIEW over it.
// Returns the descriptor plus any legacy warnings.
export function normalizeDescriptor(config: any, activeFeatures?: Record<string, any>):
  { descriptor: Descriptor, warnings: string[] } {

  const warnings: string[] = []
  const main = config?.main || {}
  const options = config?.options || {}

  const name = String(main.name || '')
  let slug: string = main.slug
  if (null == slug || '' === slug) {
    slug = legacySlug(name)
    warnings.push('descriptor: legacy config has no main.slug; derived "' +
      slug + '" from the camel name - hyphens in the original name are lost')
  }

  const version = null != main.version ? String(main.version) : '0.0.0'
  const target = null != main.target ? String(main.target) : 'unknown'

  const server: { name: string, value: string }[] = []
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

  const entities: Record<string, DescriptorEntity> = {}
  const entdefs = config?.entity || {}
  for (const ename of Object.keys(entdefs).sort()) {
    const e = entdefs[ename] || {}
    const fields: Record<string, { kind: string }> = {}
    for (const f of e.fields || []) {
      if (null != f && null != f.name) {
        fields[f.name] = { kind: String(f.kind || f.type || '') }
      }
    }
    const ops: Record<string, { points: DescriptorPoint[] }> = {}
    const opdefs = e.op || {}
    for (const opname of Object.keys(opdefs).sort()) {
      const op = opdefs[opname] || {}
      const points: DescriptorPoint[] = []
      for (const p of op.points || []) {
        if (null == p) { continue }
        const point: DescriptorPoint = {
          method: String(p.method || ''),
          path: String(p.orig || p.path || ''),
          params: (p.parts || []).filter((s: any) => 'string' === typeof s &&
            s.startsWith(':')).map((s: string) => s.slice(1)),
        }
        if (null != p.select) { point.select = p.select }
        points.push(point)
      }
      ops[opname] = { points }
    }
    entities[ename] = { fields, ops }
  }

  const features: {
    name: string, active: boolean,
    options?: Record<string, any>, transport?: string,
  }[] = []
  const fdefs = config?.feature || {}
  const factive = activeFeatures || {}
  for (const fname of Object.keys(fdefs).sort()) {
    const fdef = fdefs[fname] || {}
    const row: any = { name: fname, active: true === factive[fname]?.active }
    if (null != fdef.options && 'object' === typeof fdef.options) {
      row.options = fdef.options
    }
    if (null != fdef.transport && '' !== fdef.transport) {
      row.transport = String(fdef.transport)
    }
    features.push(row)
  }

  const descriptor: Descriptor = {
    station: 1,
    name, slug,
    envtoken: envtoken(slug),
    version, target,
    base: String(options.base || ''),
    server, auth, entities, features,
  }

  return { descriptor, warnings }
}

const UTF8 = new TextEncoder()

function bytecompare(a: string, b: string): number {
  const ab = UTF8.encode(a), bb = UTF8.encode(b)
  const n = ab.length < bb.length ? ab.length : bb.length
  for (let i = 0; i < n; i++) {
    if (ab[i] !== bb[i]) { return ab[i] - bb[i] }
  }
  return ab.length - bb.length
}

export function canonicalSerialize(value: any): string {
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
    keys.sort(bytecompare)
    return '{' + keys.map((k) =>
      JSON.stringify(k) + ':' + canonicalSerialize(value[k])).join(',') + '}'
  }
  return 'null'
}
