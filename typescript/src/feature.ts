/* Feature management (design §8): the three-level merge, the
 * constraint-and-band resolver, and the descriptor-derived checker.
 *
 * The resolver is written to voxgig/plugin's §7 semantics so plugin can
 * extract it — this is one of the pieces the joint plan means by
 * "station builds natively to plugin's semantics". Keeping the two
 * spellings identical is what C4 holds station to. */

import { StationError } from './error'

// ---------------------------------------------------------------------
// §8.3 — the merge
// ---------------------------------------------------------------------

/** Reserved on a feature entry: not options, and never passed through
 * to the SDK's own option map. */
export const RESERVED_KEYS = ['active', 'order']

/** The six sources, in §3.3's order extended by the profile level:
 *
 *   1 base.feature            4 overlay.feature
 *   2 base.api[<api>].feature 5 overlay.api[<api>].feature
 *   3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
 *
 * PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
 * the narrower block wins — the same principle as §3.3, one level down.
 *
 * `feature` is the ONE key where §3.3's shallow-per-key rule is wrong:
 * composition is the entire point, a fleet default plus a per-instance
 * tweak. So it is a TWO-LEVEL merge — per feature name, then per option
 * key — and no deeper. A map-valued option REPLACES wholesale, which is
 * what `{"$MERGE": {"deep": 2}}` states and what a port defaulting to a
 * deep merge would silently get wrong.
 *
 * Same defaults-after-merge rule as §3.3, one level down: an entry
 * mentioned at one level with only a tuning key must NOT synthesize
 * `active` and switch on a feature a broader level turned off. That is
 * the §3.3 defect one level down, and it is why the caller passes RAW
 * blocks here. */
export function mergefeatures(sources: any[]): { [name: string]: any } {
  const out: { [name: string]: any } = {}
  for (const src of sources) {
    if (!ismap(src)) { continue }
    for (const name of Object.keys(src)) {
      const entry = src[name]
      if (!ismap(entry)) { out[name] = entry; continue }
      // Per option key, and NOT deeper.
      out[name] = { ...(ismap(out[name]) ? out[name] : {}), ...entry }
    }
  }
  return out
}

/** The six sources for one instance, in order. Assembled here rather
 * than at the call site so the order lives in exactly one place. */
export function featuresources(
  base: any, overlay: any, api: string, ref: string
): any[] {
  return [
    base?.feature,
    base?.api?.[api]?.feature,
    base?.sdk?.[ref]?.feature,
    overlay?.feature,
    overlay?.api?.[api]?.feature,
    overlay?.sdk?.[ref]?.feature,
  ]
}

// ---------------------------------------------------------------------
// §8.4 — activation and order
// ---------------------------------------------------------------------

/** `test` substitutes the base transport, so it takes the innermost
 * band; `station` sits immediately outside it, pinned; everything else
 * is band 0, outside station.
 *
 * THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
 * than as a special case: a project that writes no `order` anywhere
 * sees exactly today's nesting, and sdkgen's two `makeOptions` special
 * cases become two band values rather than two branches. */
export const BAND_DEFAULT = 0
export const BAND_STATION = 100
export const BAND_TEST = 200

/** Higher is further IN. */
export function defaultband(name: string): number {
  if ('test' === name) { return BAND_TEST }
  if ('station' === name) { return BAND_STATION }
  return BAND_DEFAULT
}

export type Ordered = { name: string, band: number, entry: any }

/** Resolve the activation order: constraints, then bands, then the
 * feature's position in the merged map.
 *
 * `before`/`after` take a feature name or a list of them and are
 * SATISFIED VACUOUSLY when the named feature is absent — `after: 'test'`
 * loads fine in a project with no test feature, which is sdkgen's
 * `__after__` behaviour kept rather than reinvented.
 *
 * Constraints beat bands; bands break ties no constraint decides;
 * remaining ties break by declaration position, so the result is a
 * stable topological sort with no alphabetical accident in it.
 *
 * Returns OUTERMOST FIRST, which is the array form the constructor
 * takes and the direction plugin's chain composes in. */
export function resolveorder(merged: { [name: string]: any }): Ordered[] {
  const names = Object.keys(merged).filter((n) => active(merged[n]))
  const pos = new Map<string, number>()
  names.forEach((n, i) => pos.set(n, i))

  const band = new Map<string, number>()
  for (const n of names) {
    const o = ismap(merged[n]) ? merged[n].order : undefined
    const b = ismap(o) && 'number' === typeof o.band ? o.band : defaultband(n)
    band.set(n, b)
  }

  // edges: from OUTER to INNER. `after: X` means "further in than X".
  const inner = new Map<string, Set<string>>()
  for (const n of names) { inner.set(n, new Set()) }

  const listof = (v: any): string[] =>
    null == v ? [] : (Array.isArray(v) ? v : [v]).map(String)

  for (const n of names) {
    const o = ismap(merged[n]) ? merged[n].order : undefined
    if (!ismap(o)) { continue }
    // Vacuous when absent: an unknown name is not an error here.
    for (const other of listof(o.after)) {
      if (inner.has(other)) { inner.get(other)!.add(n) }
    }
    for (const other of listof(o.before)) {
      if (inner.has(other)) { inner.get(n)!.add(other) }
    }
  }

  const indeg = new Map<string, number>()
  for (const n of names) { indeg.set(n, 0) }
  for (const n of names) {
    for (const m of inner.get(n)!) { indeg.set(m, (indeg.get(m) || 0) + 1) }
  }

  // Kahn, picking the lowest band first (outermost), then declaration
  // position — so ties break the same way in every port.
  const ready: string[] = names.filter((n) => 0 === indeg.get(n))
  const out: Ordered[] = []
  const pick = (): string => {
    ready.sort((a, b) => {
      const d = band.get(a)! - band.get(b)!
      return 0 !== d ? d : pos.get(a)! - pos.get(b)!
    })
    return ready.shift()!
  }

  while (0 < ready.length) {
    const n = pick()
    out.push({ name: n, band: band.get(n)!, entry: merged[n] })
    for (const m of inner.get(n)!) {
      indeg.set(m, indeg.get(m)! - 1)
      if (0 === indeg.get(m)) { ready.push(m) }
    }
  }

  if (out.length !== names.length) {
    const stuck = names.filter((n) => !out.some((o) => o.name === n)).sort()
    throw new StationError('station_feature_order',
      'feature ordering constraints form a cycle among [' +
      stuck.join(', ') + ']')
  }

  return out
}

/** A feature named in the config is one you are ASKING for, so an entry
 * with no `active` is active. */
function active(entry: any): boolean {
  if (!ismap(entry)) { return false !== entry }
  return false !== entry.active
}

/** Station's own position is PINNED and not orderable (§8.4): an order
 * that moves `station` away from immediately-outside-the-base is
 * REJECTED, not honoured.
 *
 * The pin is `innermost`, and the spelling matters. A chain composes
 * with the FIRST binding outermost, so a pin written in sort terms —
 * "station first" — would place every other wrapper between the adapter
 * and the base: the exact inversion of the invariant, and one that
 * would leave station's wire-truth events observing the wrong boundary
 * while still looking ordered. */
export function checkpin(ordered: Ordered[]): void {
  const i = ordered.findIndex((o) => 'station' === o.name)
  if (-1 === i) { return }

  const base = ordered.findIndex((o) => 'test' === o.name)
  // station must be the innermost wrapper: last, or immediately
  // outside the base-transport feature when one is active.
  const want = -1 === base ? ordered.length - 1 : base - 1
  if (i !== want) {
    throw new StationError('station_feature_order',
      'an ordering would move `station` away from immediately outside ' +
      'the base transport; its position is pinned innermost and is not ' +
      'orderable (§8.4)')
  }
}

// ---------------------------------------------------------------------
// §8.5 — the checker, derived from the descriptor
// ---------------------------------------------------------------------

export type FeatureFault = {
  code: string
  feature: string
  key?: string
  message: string
}

/** Check a merged feature map against the SDK'S OWN DECLARATION.
 *
 * The schema arrives with the FACTORY rather than with a live client
 * (§6.2), so this needs no construction and no network — which is what
 * lets `check()` run it for every instance in CI.
 *
 * Derived from the descriptor, never hand-written, so it cannot drift:
 * when a feature gains an option, the next regeneration teaches station
 * about it with no station change.
 *
 * SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED, and
 * that limit is real. An empty list default says nothing reliable about
 * its element type and a nested map default says nothing about its
 * value shapes, so `methods: [{}]` against a `['GET']` default is
 * caught while `noProxy: []` accepts anything list-shaped. Closing that
 * needs the feature model to declare an explicit option schema rather
 * than only a default. */
export function checkfeatures(
  merged: { [name: string]: any }, descriptor: any
): FeatureFault[] {
  const faults: FeatureFault[] = []
  const declared: any[] = descriptor?.features || []
  const byname = new Map<string, any>()
  for (const f of declared) { byname.set(String(f.name), f) }

  for (const name of Object.keys(merged).sort()) {
    const spec = byname.get(name)
    if (null == spec) {
      faults.push({
        code: 'station_feature_unknown',
        feature: name,
        message: 'the SDK has no feature "' + name + '"; it declares [' +
          Array.from(byname.keys()).sort().join(', ') + ']',
      })
      continue
    }

    const entry = merged[name]
    if (!ismap(entry)) { continue }
    const defaults = ismap(spec.options) ? spec.options : {}

    for (const key of Object.keys(entry).sort()) {
      if (-1 !== RESERVED_KEYS.indexOf(key)) { continue }

      if (!(key in defaults)) {
        // THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is accepted
        // and silently ignored today, because makeOptions' feature spec
        // is `$OPEN` per feature so the SDK cannot catch it and nothing
        // else looks.
        faults.push({
          code: 'station_feature_option',
          feature: name,
          key,
          message: 'feature "' + name + '" declares no option "' + key +
            '"; it declares [' + Object.keys(defaults).sort().join(', ') + ']',
        })
        continue
      }

      const want = kindof(defaults[key])
      const got = kindof(entry[key])
      if (want !== got) {
        faults.push({
          code: 'station_feature_option',
          feature: name,
          key,
          message: 'feature "' + name + '" option "' + key + '" expects ' +
            want + ', but found ' + got + ': ' + JSON.stringify(entry[key]),
        })
      }
    }
  }

  return faults
}

/** Compose the merged map into the ORDERED ARRAY FORM the constructor
 * takes. No new seam: it is what `connect()` already does for station's
 * own placement, with more in it. */
export function composefeatures(ordered: Ordered[]): any[] {
  return ordered.map((o) => {
    const entry = ismap(o.entry) ? o.entry : {}
    const out: any = { name: o.name, active: true }
    for (const k of Object.keys(entry)) {
      if (-1 !== RESERVED_KEYS.indexOf(k)) { continue }
      out[k] = entry[k]
    }
    return out
  })
}

function kindof(v: any): string {
  if (null === v || undefined === v) { return 'null' }
  if (Array.isArray(v)) { return 'list' }
  if ('number' === typeof v) { return 'number' }
  if ('object' === typeof v) { return 'map' }
  return typeof v
}

function ismap(v: any): boolean {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}
