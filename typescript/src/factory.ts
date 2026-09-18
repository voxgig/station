
import { StationError } from './error'
import { normalizeDescriptor } from './descriptor'

export type Factory = {
  construct: (options: any) => any
  config: any
}

export type FactoryEntry = {
  api: string
  construct: (options: any) => any
  config: any
  descriptor: any
  warnings: string[]
}

const TABLE = new Map<string, FactoryEntry>()

export function provide(api: string, factory: Factory): FactoryEntry {
  const slug = String(api)
  const prior = TABLE.get(slug)
  if (null != prior) {
    if (prior.construct === factory.construct && prior.config === factory.config) {
      return prior
    }
    throw new StationError('station_factory_conflict',
      'two different factories registered for api "' + slug + '"; a ' +
      'process has one build of an SDK, and picking between two ' +
      'silently is not a thing to do quietly')
  }

  // AT PROVIDE TIME, which is the whole point of carrying `config`.
  const { descriptor, warnings } = normalizeDescriptor(factory.config, undefined)
  const entry: FactoryEntry = {
    api: slug,
    construct: factory.construct,
    config: factory.config,
    descriptor,
    warnings,
  }
  TABLE.set(slug, entry)
  return entry
}

export function factoryFor(api: string): FactoryEntry | undefined {
  return TABLE.get(String(api))
}

export function provided(): string[] {
  return Array.from(TABLE.keys()).sort()
}

export function resetFactories(): void {
  TABLE.clear()
}
