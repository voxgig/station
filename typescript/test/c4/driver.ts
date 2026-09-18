
import { checkpin, resolveorder } from '../../src/feature'
import { CodeMap, NoCounterpart, isMap } from './corpus'

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
  let entries = new Map<string, Ent>()
  let last: any = undefined

  for (const c of cmds || []) {
    if (true === c.catch) {
      throw new NoCounterpart('the catch modifier')
    }
    switch (c.do) {
      case 'host':
        allow(c, ['do', 'points'])
        entries = new Map()
        xpoints(c.points)
        break

      case 'define':
        allow(c, ['do', 'name'])
        break

      case 'ready':
        allow(c, ['do', 'ref', 'order', 'definition'])
        upsert(entries, xref(c.ref), true, xorder(c.order))
        break

      case 'load':
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
  }
}

function bytewise(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

export function xorderentry(e: any): any {
  const out = e.match && e.match.out
  if (!isMap(out) || !Array.isArray(out.result)) { return e }
  return {
    ...e,
    match: { ...e.match, out: { ...out, result: out.result.map(xref) } },
  }
}
