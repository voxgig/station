/* C4b `order`: plugin's driver commands (DOCS.md §4) interpreted as a
 * THIN STATE LAYER over station's own resolver.
 *
 * The subject under test is src/feature.ts - `resolveorder` plus
 * `checkpin` - the code the joint plan means by "station builds
 * natively to plugin's §7 semantics". Everything else here is
 * bookkeeping the plugin host would do around its sort: which refs are
 * live, in what declaration order, carrying which ordering block.
 * The layer interprets ONLY the command subset the `order` section
 * uses (verified by scanning the section: host, define, ready, load,
 * activate, deactivate, unload, apply, order); any other verb - and
 * any vocabulary within a verb that station has no counterpart for -
 * raises NoCounterpart, so an entry missing from the skip manifest
 * fails instead of half-running.
 *
 * Correspondences, stated once:
 *
 * - A readied REF is a feature NAME in station's merged map. Station's
 *   features have no name/tag split, so the ref string itself is the
 *   name; declaration order is map insertion order, which is the `pos`
 *   station's resolver breaks final ties by - the same tie plugin
 *   breaks by seq-then-pos, and the seqtie entry is the one that
 *   observes the difference in a port that gets it wrong.
 * - `order` (the command) is `resolveorder` + `checkpin`, exactly the
 *   pair station's own `featuresOf` runs.
 * - THE PINNED NAME IS TRANSLATED: plugin's driver pins its `adapter`
 *   probe; station's pin machinery is `checkpin` - exactly one
 *   reserved name, `station`, pinned innermost, placed by BAND_STATION
 *   rather than by a placement pass (feature.ts §8.4: "two band values
 *   rather than two special cases"). So refs named `adapter` translate
 *   to the literal feature name `station`, in commands, in ordering
 *   constraints and in expected results alike. A pin spelling other
 *   than innermost-by-that-one-name (outermost, multi-name pin maps)
 *   has no station counterpart and raises NoCounterpart.
 */

import { checkpin, resolveorder } from '../../src/feature'
import { CodeMap, NoCounterpart, isMap } from './corpus'

/** Expected plugin code -> station code, for this section. Both order
 * failures are one station code: station's design folds cycle and
 * pin violations into `station_feature_order` (§8.4). */
export const ORDER_CODES: CodeMap = {
  plugin_order_cycle: 'station_feature_order',
  plugin_order_pinned: 'station_feature_order',
}

/** plugin's pinned probe name -> station's pinned feature name. The
 * tag is dropped, not kept: station's reserved entry is the bare name
 * `station` (checkpin and BAND_STATION match on exactly that), and
 * there is exactly one of it per wrap. */
export function xref(ref: string): string {
  if ('adapter' === ref || String(ref).startsWith('adapter$')) { return 'station' }
  return String(ref)
}

type Ent = { active: boolean, order?: any }

export function drive(cmds: any[]): any {
  // Insertion order IS declaration order, and survives deactivation
  // (recompute keeps a reactivated instance's position) but not unload
  // (seqtie: a fresh declaration after an unload goes to the end).
  let entries = new Map<string, Ent>()
  let last: any = undefined

  for (const c of cmds || []) {
    if (true === c.catch) {
      // §4.1's catch is how a FAILED instance stays observable - a
      // lifecycle concern; nothing in the order section uses it.
      throw new NoCounterpart('the catch modifier')
    }
    switch (c.do) {
      case 'host':
        allow(c, ['do', 'points'])
        entries = new Map()
        xpoints(c.points)
        break

      case 'define':
        // The catalog names a probe; ordering is per-ref and the ref
        // string is the identity here, so there is nothing to record.
        allow(c, ['do', 'name'])
        break

      case 'ready':
        allow(c, ['do', 'ref', 'order', 'definition'])
        upsert(entries, xref(c.ref), true, xorder(c.order))
        break

      case 'load':
        // declared+loaded, not live: present, but not in the order.
        allow(c, ['do', 'ref', 'order', 'definition'])
        upsert(entries, xref(c.ref), false, xorder(c.order))
        break

      case 'activate':
        allow(c, ['do', 'ref'])
        setactive(entries, xref(c.ref), true)
        break

      case 'deactivate':
        allow(c, ['do', 'ref'])
        setactive(entries, xref(c.ref), false)
        break

      case 'unload':
        allow(c, ['do', 'ref'])
        entries.delete(xref(c.ref))
        break

      case 'apply':
        allow(c, ['do', 'doc'])
        applydoc(entries, c.doc)
        break

      case 'order': {
        allow(c, ['do', 'point'])
        // All live instances participate whatever the point - plugin's
        // host.order(point) resolves over the whole live set too, the
        // point only contributes its pin. Station's pin needs no
        // lookup: checkpin always guards the one name it owns.
        const merged: any = {}
        for (const [name, ent] of entries) {
          merged[name] = { active: ent.active, order: ent.order }
        }
        const ordered = resolveorder(merged)
        checkpin(ordered)
        last = ordered.map((o) => o.name)
        break
      }

      default:
        throw new NoCounterpart('driver command `' + c.do + '`')
    }
  }

  // The slice of §4.5's canonical observable this section asserts on.
  return { result: undefined === last ? null : last }
}

/** A command may only carry the keys its verb owns - an unknown key is
 * vocabulary this layer would silently drop, which is exactly what the
 * skip manifest exists to prevent. */
function allow(c: any, keys: string[]): void {
  for (const k of Object.keys(c)) {
    if (-1 === keys.indexOf(k)) {
      throw new NoCounterpart('command key `' + k + '` on `' + c.do + '`')
    }
  }
}

function upsert(entries: Map<string, Ent>, name: string, active: boolean, order: any): void {
  const prior = entries.get(name)
  if (prior) {
    prior.active = active
    if (undefined !== order) { prior.order = order }
    return
  }
  entries.set(name, { active, order })
}

function setactive(entries: Map<string, Ent>, name: string, active: boolean): void {
  const ent = entries.get(name)
  if (ent) { ent.active = active }
}

/** An applied document declares refs in the order the form implies -
 * array position for the array form, sorted refs for the map form
 * (plugin §9.1) - and a re-apply restates positions, so each ref is
 * re-inserted at its document position. `active: false` bars it;
 * `start: "lazy"` leaves it declared until a later `ready`. */
function applydoc(entries: Map<string, Ent>, doc: any): void {
  if (!isMap(doc)) { throw new NoCounterpart('a non-map apply document') }
  for (const k of Object.keys(doc)) {
    if ('instance' !== k && 'plugin' !== k) {
      throw new NoCounterpart('apply document key `' + k + '`')
    }
  }

  const src = doc.instance
  const list: { ref: string, entry: any }[] = []
  if (Array.isArray(src)) {
    for (const item of src) { list.push({ ref: xref(item.ref), entry: item }) }
  }
  else if (isMap(src)) {
    for (const key of Object.keys(src).sort(bytewise)) {
      list.push({ ref: xref(key), entry: src[key] })
    }
  }

  for (const { ref, entry } of list) {
    for (const k of Object.keys(entry)) {
      if (-1 === ['ref', 'active', 'start', 'order', 'options'].indexOf(k)) {
        throw new NoCounterpart('apply entry key `' + k + '`')
      }
    }
    const live = false !== entry.active && 'lazy' !== entry.start
    entries.delete(ref)
    entries.set(ref, { active: live, order: xorder(entry.order) })
  }
}

/** The ordering block travels as-is - station's resolver reads the
 * same {before, after, band} map - except that constraint targets are
 * refs, so the pinned-name translation applies to them too. */
function xorder(order: any): any {
  if (null == order) { return undefined }
  if (!isMap(order)) { throw new NoCounterpart('a non-map order block') }
  const out: any = {}
  for (const k of Object.keys(order)) {
    if ('band' === k) { out.band = order.band; continue }
    if ('before' === k || 'after' === k) {
      const v = order[k]
      out[k] = Array.isArray(v) ? v.map(xref) : xref(v)
      continue
    }
    throw new NoCounterpart('order block key `' + k + '`')
  }
  return out
}

/** A `host` command's point declarations. The only pin station can
 * stand behind is its own: one name, innermost (checkpin). The name
 * arrives as `adapter` and translates like every other ref; any other
 * pin spelling has no counterpart. */
function xpoints(points: any): void {
  if (null == points) { return }
  for (const pname of Object.keys(points)) {
    const spec = points[pname]
    if (!isMap(spec)) { continue }
    for (const k of Object.keys(spec)) {
      if ('kind' !== k && 'pin' !== k) {
        throw new NoCounterpart('point spec key `' + k + '`')
      }
    }
    if (undefined === spec.pin) { continue }
    const names = Object.keys(spec.pin)
    for (const name of names) {
      if ('station' !== xref(name) || 'innermost' !== spec.pin[name]) {
        throw new NoCounterpart(
          'pin `' + name + ': ' + spec.pin[name] + '` (station pins ' +
          'exactly one name, its own, innermost)')
      }
    }
    // Nothing to record: checkpin runs on every order and BAND_STATION
    // does the placement.
  }
}

/** Byte-wise for ASCII, matching plugin's map-form order rule. */
function bytewise(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

/** Expected results in the order section are ref lists; the pinned
 * name translates there exactly as it does in commands, so the
 * expectation stays entry vocabulary and station's output is never
 * touched. */
export function xorderentry(e: any): any {
  const out = e.match && e.match.out
  if (!isMap(out) || !Array.isArray(out.result)) { return e }
  return {
    ...e,
    match: { ...e.match, out: { ...out, result: out.result.map(xref) } },
  }
}
