
import { PluginError, makecatalog, makehost } from '@voxgig/plugin'
import type { Definition } from '@voxgig/plugin'

export type { Definition }

export type ExtensionRow = { name: string, status: string }

/** What the Station knows of an SDK before it constructs one. */
export type SdkInfo = { name?: string, api?: string, descriptor?: any }

/** A client the Station has bound, which may still be under construction. */
export type BoundSdk = { name: string, api: string, descriptor: any, client: any }

export type Extensions = {
  use(definition: Definition, options?: { [key: string]: any }): void
  list(): ExtensionRow[]
  exports(spec: string): any
  feature(feature: any, info: SdkInfo): any
  bound(sdk: BoundSdk): unknown[]
  close(): void
}

const STATION = 'station'

export const FEATURE_POINT = 'sdk.feature'
export const BOUND_POINT = 'sdk.bound'

const POINTS: any = {
  [FEATURE_POINT]: { kind: 'chain', base: (feature: any) => feature },
  [BOUND_POINT]: { kind: 'hook', mode: 'serial' },
}

// The host's first instance is the Station itself, exported as
// `station/station`: an extension reads it there in its own `activate`.
export function makeextensions(station: unknown): Extensions {
  const host = makehost({
    points: POINTS,
    catalog: makecatalog([{
      name: STATION,
      define: (inst: any) => inst.export(STATION, station),
    }]),
  })
  host.load(STATION)
  host.activate(STATION)

  const used = new Map<string, Definition>()

  return {
    use(definition, options) {
      const name = definition && definition.name
      if (STATION === name) {
        throw new PluginError('plugin_ref_reserved',
          'ref is reserved by the host: ' + STATION, { ref: STATION })
      }
      // plugin's host keeps its instances in a plain object.
      if (Object.prototype.hasOwnProperty.call(Object.prototype, name)) {
        throw new PluginError('plugin_bad_name',
          'extension name is held by Object.prototype: ' + name, { name })
      }
      if (used.has(name) && used.get(name) !== definition) {
        throw new PluginError('plugin_ref_duplicate',
          'extension already loaded: ' + name, { ref: name })
      }
      host.define(definition)
      used.set(name, definition)
      host.load(name, { options: options || {} })
      host.activate(name)
    },

    list() {
      const all = host.list()
      return Object.keys(all).filter((ref) => STATION !== ref).sort()
        .map((ref) => ({ name: ref, status: all[ref] }))
    },

    exports: (spec) => host.exports(spec),

    feature: (feature, info) => host.call(FEATURE_POINT, feature, info),

    bound: (sdk) => host.emit(BOUND_POINT, sdk) || [],

    close: () => host.close(),
  }
}


/** A feature collection, in either of sdkgen's forms, with one feature
 * more switched on, or unchanged when the SDK was generated without it. */
export function withfeature(feature: any, name: string, entry: any, descriptor?: any): any {
  if (!hasfeature(descriptor, name)) { return feature }
  if (Array.isArray(feature)) {
    const at = feature.findIndex((f: any) => name === f?.name)
    if (-1 === at) { return [...feature, { ...entry, name }] }
    const out = feature.slice()
    out[at] = { ...combine(feature[at], entry), name }
    return out
  }
  const map = null != feature && 'object' === typeof feature ? feature : {}
  return { ...map, [name]: combine(map[name], entry) }
}

export function hasfeature(descriptor: any, name: string): boolean {
  return Array.isArray(descriptor?.features) &&
    descriptor.features.some((f: any) => name === f?.name)
}

// The caller's settings win. Where both set a function, the caller's
// runs first and its result stands, and the extension's cannot fail it.
function combine(own: any, add: any): any {
  if (null == own || 'object' !== typeof own) { return { ...add } }
  const out: any = { ...add }
  for (const key of Object.keys(own)) {
    const mine = own[key]
    const theirs = add[key]
    out[key] = 'function' === typeof mine && 'function' === typeof theirs
      ? both(mine, theirs) : mine
  }
  return out
}

function both(first: (...args: any[]) => any, then: (...args: any[]) => any) {
  return function (this: any, ...args: any[]) {
    const out = first.apply(this, args)
    try { then.apply(this, args) }
    catch (_err) { /* an observer does not fail the SDK's call */ }
    return out
  }
}
