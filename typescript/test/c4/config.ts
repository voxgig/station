/* C4a `config`: plugin's document vocabulary translated into station's
 * config grammar, resolved by STATION'S OWN resolver, and projected
 * into the corpus's observable vocabulary.
 *
 * The mapping is exactly the joint agreement's tables
 * (docs/design/station-and-plugin.md §3.1/§3.2):
 *
 *   plugin `instance.<ref>`                -> station `sdk.<ref>`
 *   plugin `default.<name>`                -> station `api.<slug>`
 *   plugin document base                   -> station `profiles.default`
 *   plugin `profile.<p>` overlay           -> station `profiles.<p>`
 *   plugin `keys: {instance, default}`     -> already station's words
 *
 * and the resolution the entries are compared on is `resolveProfile`
 * (src/profile.ts) - the four documented middle rungs of the ladder
 * (levels 3-6), with defaults-after-merge. The translator handles INPUT
 * vocabulary only; the values compared are station's own, untouched.
 * Anything outside the documented mapping - the array (positional)
 * document form, `start`, `reserved`, ladder levels 1-2 and 7-10
 * (shape/hostdefaults/env/hostoptions/loadoptions/patch), `$MERGE`
 * shape parameters - raises NoCounterpart, and every entry that uses it
 * is pinned in the skip manifest with the reason. */

import { resolveProfile } from '../../src/profile'
import { Entry, NoCounterpart, isMap } from './corpus'

const LADDER_OUTSIDE = [
  // levels 1-2 and 7-10 of plugin's ten-level ladder. Station's §3.2
  // mapping covers levels 3-6 only; these have no station counterpart
  // in resolveProfile (station's own env/open()-opts precedence applies
  // to profile SELECTION, not to per-instance option layering).
  'shape', 'hostdefaults', 'env', 'hostoptions', 'loadoptions', 'patch',
]

/** plugin {doc, profile?, keys?} -> a station config plus the profile
 * name to resolve. Pure input translation. */
export function xconfig(vin: any): { config: any, profile: string } {
  for (const k of LADDER_OUTSIDE) {
    if (undefined !== vin[k]) {
      throw new NoCounterpart('ladder level carried by `' + k + '`')
    }
  }
  if (undefined !== vin.reserved) {
    // Station's reservation is `feature.station` in the FEATURE
    // namespace (§3.3 of the joint doc), not a bar on instance refs.
    throw new NoCounterpart('reserved instance refs')
  }

  const doc = vin.doc || {}
  const keys = vin.keys || {}
  const ikey = keys.instance || 'instance'
  const dkey = keys.default || 'default'

  // The rename applies at the document root and at every overlay root,
  // and nowhere deeper - plugin §9.1, and the reason normkeys pins a
  // `sdk` key INSIDE options staying untouched.
  const profiles: any = {
    default: xprofile(doc, ikey, dkey, ['profile', 'plugin']),
  }
  const overlays = doc.profile || {}
  for (const pname of Object.keys(overlays)) {
    if ('default' === pname) {
      // plugin's base document IS its default profile; a named overlay
      // called `default` would collide with it in station's grammar.
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

// ---------------------------------------------------------------------
// Subjects
// ---------------------------------------------------------------------

/** norm* groups: resolve with station's resolver and project into the
 * corpus's observable names. The values are station's own:
 *
 *   order    -> the resolved instance set, in station's order (its
 *               registry is a keyed map with sorted refs - which is
 *               also plugin's order for the map document form)
 *   instance -> the resolved per-instance blocks (station's blocks,
 *               with `options` spelled {} where station spells absence)
 *   default  -> the api-level defaults in effect (ResolvedProfile.api)
 *
 * This is projection, not post-processing: no value is reordered,
 * merged or invented here. */
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
  // Station spells "no options resolved" as absence; the corpus spells
  // it {}. A spelling projection, not a value change.
  return block?.options ?? {}
}

// ---------------------------------------------------------------------
// Expectation translation for norm* entries
// ---------------------------------------------------------------------

/** plugin's normalizeconfig does NOT merge option layers - it emits
 * `optionlayers`, levels 3-6 in ladder order, because merge depth is
 * the definition shape's to decide (plugin §9.4). Station has no
 * layered form: its merge behaviour is fixed by design (§3.3 shallow
 * per block key; station-and-plugin.md §2.5 pins `options` as replace),
 * so it resolves immediately.
 *
 * A SINGLE layer translates losslessly - one layer resolves to itself
 * under any merge rule - so `optionlayers: [X]` becomes `options: X`.
 * A multi-layer expectation would force this adapter to APPLY a merge
 * rule to the expectation, which is semantics rather than vocabulary:
 * those entries are pinned in the skip manifest instead, and reaching
 * one here is a harness error. */
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
