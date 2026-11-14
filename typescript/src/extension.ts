
import { PluginError, makecatalog, makehost } from '@voxgig/plugin'
import type { Definition } from '@voxgig/plugin'

export type { Definition }

export type ExtensionRow = { name: string, status: string }

export type Extensions = {
  use(definition: Definition, options?: { [key: string]: any }): void
  list(): ExtensionRow[]
  exports(spec: string): any
  close(): void
}

const STATION = 'station'

// The host's first instance is the Station itself, exported as
// `station/station`: an extension reads it there in its own `activate`.
export function makeextensions(station: unknown): Extensions {
  const host = makehost({
    catalog: makecatalog([{
      name: STATION,
      define: (inst: any) => inst.export(STATION, station),
    }]),
  })
  host.load(STATION)
  host.activate(STATION)

  const used: { [name: string]: Definition } = {}

  return {
    use(definition, options) {
      const name = definition && definition.name
      if (STATION === name) {
        throw new PluginError('plugin_ref_reserved',
          'ref is reserved by the host: ' + STATION, { ref: STATION })
      }
      if (undefined !== used[name] && used[name] !== definition) {
        throw new PluginError('plugin_ref_duplicate',
          'extension already loaded: ' + name, { ref: name })
      }
      host.define(definition)
      used[name] = definition
      host.load(name, { options: options || {} })
      host.activate(name)
    },

    list() {
      const all = host.list()
      return Object.keys(all).filter((ref) => STATION !== ref).sort()
        .map((ref) => ({ name: ref, status: all[ref] }))
    },

    exports: (spec) => host.exports(spec),

    close: () => host.close(),
  }
}
