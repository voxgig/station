
import { featuresources, mergefeatures } from '../../src/feature'
import { resolveProfile } from '../../src/profile'
import { Entry, NoCounterpart, isMap } from './corpus'

const LADDER_OUTSIDE = [
  'shape', 'hostdefaults', 'env', 'hostoptions', 'loadoptions', 'patch',
]

export function xconfig(vin: any): { config: any, profile: string } {
  for (const k of LADDER_OUTSIDE) {
    if (undefined !== vin[k]) {
      throw new NoCounterpart('ladder level carried by `' + k + '`')
    }
  }
  if (undefined !== vin.reserved) {
    throw new NoCounterpart('reserved instance refs')
  }

  const doc = vin.doc || {}
  const keys = vin.keys || {}
  const ikey = keys.instance || 'instance'
  const dkey = keys.default || 'default'

  const profiles: any = {
    default: xprofile(doc, ikey, dkey, ['profile', 'plugin']),
  }
  const overlays = doc.profile || {}
  for (const pname of Object.keys(overlays)) {
    if ('default' === pname) {
      throw new NoCounterpart('an overlay profile named `default`')
    }
    profiles[pname] = xprofile(overlays[pname], ikey, dkey, [])
  }

  return {
    config: { station: 1, profiles },
    profile: vin.profile || 'default',
  }
}

function xprofile(src: any, ikey: string, dkey: string, extra: string[]): any {
  for (const k of Object.keys(src)) {
    if (k !== ikey && k !== dkey && -1 === extra.indexOf(k)) {
      throw new NoCounterpart('document key `' + k + '`')
    }
  }
  return {
    api: xdefaultmap(src[dkey]),
    sdk: xinstancemap(src[ikey]),
  }
}

/** plugin `instance` -> station `sdk`. MAP FORM ONLY: station's config
 * grammar has no positional (array) form, so an array document raises
 * NoCounterpart and its entries are skipped. Keys are used verbatim -
 * station has no ref canonicalization, and the mapped entries all use
 * canonical refs. */
function xinstancemap(src: any): any {
  if (null == src) { return {} }
  if (Array.isArray(src)) {
    throw new NoCounterpart('the array (positional) instance form')
  }
  const out: any = {}
  for (const ref of Object.keys(src)) {
    out[ref] = xentryblock(src[ref])
  }
  return out
}

function xdefaultmap(src: any): any {
  if (null == src) { return {} }
  if (!isMap(src)) { throw new NoCounterpart('a non-map default map') }
  const out: any = {}
  for (const name of Object.keys(src)) {
    out[name] = xentryblock(src[name])
  }
  return out
}

/** One document entry -> one station block. `options` and `active`
 * translate one-to-one; `start` (lazy construction is not a config
 * concept in station) and anything else raise NoCounterpart. */
function xentryblock(entry: any): any {
  if (!isMap(entry)) { throw new NoCounterpart('a non-map entry') }
  const out: any = {}
  for (const k of Object.keys(entry)) {
    if ('options' === k || 'active' === k) { out[k] = entry[k]; continue }
    throw new NoCounterpart('entry key `' + k + '`')
  }
  return out
}


export function normsubject(e: Entry): any {
  const { config, profile } = xconfig(e.in || {})
  const resolved = resolveProfile(config, profile)

  const instance: any = {}
  for (const ref of Object.keys(resolved.sdk)) {
    const block: any = resolved.sdk[ref]
    instance[ref] = { ...block, options: block.options ?? {} }
  }

  return {
    order: Object.keys(resolved.sdk),
    instance,
    default: resolved.api,
  }
}

/** opt* groups: the resolved options of ONE instance. The ref is
 * declared (an empty block in the base profile) when the document does
 * not declare it - plugin's resolveoptions presumes the instance it is
 * resolving exists, station's resolver only resolves declared refs, so
 * declaring it is the translation of that presumption. */
export function optsubject(e: Entry): any {
  const vin = e.in || {}
  const { config, profile } = xconfig(vin)
  const ref = String(vin.ref)

  let declared = false
  for (const pname of Object.keys(config.profiles)) {
    if (undefined !== config.profiles[pname].sdk[ref]) { declared = true }
  }
  if (!declared) { config.profiles.default.sdk[ref] = {} }

  const resolved = resolveProfile(config, profile)
  const block: any = resolved.sdk[ref]
  return block?.options ?? {}
}

// ---------------------------------------------------------------------
// Expectation translation for norm* entries
// ---------------------------------------------------------------------

export function xnormentry(e: Entry): Entry {
  const out = e.match && e.match.out
  if (!isMap(out) || !isMap(out.instance)) { return e }

  const instance: any = {}
  for (const ref of Object.keys(out.instance)) {
    const exp = out.instance[ref]
    if (!isMap(exp) || undefined === exp.optionlayers) {
      instance[ref] = exp
      continue
    }
    const layers = exp.optionlayers
    if (!Array.isArray(layers) || 1 !== layers.length) {
      throw new NoCounterpart(
        'a multi-layer optionlayers expectation (station resolves ' +
        'immediately; translating it would mean merging in the adapter)')
    }
    const { optionlayers, ...rest } = exp
    instance[ref] = { ...rest, options: layers[0] }
  }

  return {
    ...e,
    match: { ...e.match, out: { ...out, instance } },
  }
}

// ---------------------------------------------------------------------
// normorder: the ordering block, in station's namespace for it
// ---------------------------------------------------------------------

export function normordersubject(e: Entry): any {
  const vin = e.in || {}
  for (const k of LADDER_OUTSIDE) {
    if (undefined !== vin[k]) {
      throw new NoCounterpart('ladder level carried by `' + k + '`')
    }
  }

  const doc = vin.doc || {}
  const ikey = (vin.keys || {}).instance || 'instance'

  const base = xorderprofile(doc, ikey, ['profile', 'plugin'])
  const pname = vin.profile || 'default'
  const overlay = 'default' === pname
    ? {}
    : xorderprofile((doc.profile || {})[pname] || {}, ikey, [])

  const merged = mergefeatures(
    featuresources({ feature: base }, { feature: overlay }, '', ''))

  return { instance: merged }
}

function xorderprofile(src: any, ikey: string, extra: string[]): any {
  if (!isMap(src)) { throw new NoCounterpart('a non-map document') }
  for (const k of Object.keys(src)) {
    if (ikey === k || extra.includes(k)) { continue }
    throw new NoCounterpart('document key `' + k + '`')
  }

  const out: any = {}
  for (const name of Object.keys(src[ikey] || {})) {
    const entry = src[ikey][name]
    if (!isMap(entry)) { throw new NoCounterpart('a non-map entry') }
    for (const k of Object.keys(entry)) {
      if ('order' === k || 'active' === k) { continue }
      throw new NoCounterpart('entry key `' + k + '`')
    }
    out[name] = { ...entry }
  }
  return out
}
