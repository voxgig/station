
import { StationError } from './error'

// ---------------------------------------------------------------------
// §8.3 — the merge
// ---------------------------------------------------------------------

export const RESERVED_KEYS = ['active', 'order']

export function mergefeatures(sources: any[]): { [name: string]: any } {
  const out: { [name: string]: any } = {}
  for (const src of sources) {
    if (!ismap(src)) { continue }
    for (const name of Object.keys(src)) {
      const entry = src[name]
      if (!ismap(entry)) { out[name] = entry; continue }
      out[name] = { ...(ismap(out[name]) ? out[name] : {}), ...entry }
    }
  }
  return out
}

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

export const BAND_DEFAULT = 0
export const BAND_STATION = 100
export const BAND_TEST = 200

export function defaultband(name: string): number {
  if ('test' === name) { return BAND_TEST }
  if ('station' === name) { return BAND_STATION }
  return BAND_DEFAULT
}

export type Ordered = { name: string, band: number, entry: any }

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

  const inner = new Map<string, Set<string>>()
  for (const n of names) { inner.set(n, new Set()) }

  const listof = (v: any): string[] =>
    null == v ? [] : (Array.isArray(v) ? v : [v]).map(String)

  for (const n of names) {
    const o = ismap(merged[n]) ? merged[n].order : undefined
    if (!ismap(o)) { continue }
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

function active(entry: any): boolean {
  if (!ismap(entry)) { return false !== entry }
  return false !== entry.active
}

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
