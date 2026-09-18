// Shared station types. Descriptor and StationEvent shapes are pinned by
// the conformance corpus (spec/station.json) - evolve them additively.

export type StationOptions = {
  profile?: string
  proxy?: 'auto' | 'off' | 'require' | string
  folder?: string
  config?: StationConfig | null
  load?: boolean
  repoScoped?: boolean
}

export type StationConfig = {
  station: number
  profiles?: Record<string, Profile>
}

export type Profile = {
  secrets?: { providers?: any[] }
  feature?: Record<string, any>
  api?: Record<string, SdkBlock>
  sdk?: Record<string, SdkBlock>
}

export type PolicyBlock = {
  hosts?: string[]
  allow?: { op?: string[], method?: string[] }
  budget?: { rps?: number, concurrency?: number }
  mode?: 'live' | 'record' | 'replay' | 'mock' | 'block'
}

export type SdkBlock = {
  package?: string
  export?: string
  base?: string
  secret?: string
  resolve?: 'library' | 'proxy'
  policy?: PolicyBlock
  capture?: 'meta' | 'headers' | 'full'
  agent?: { write: boolean }
  feature?: Record<string, any>
  options?: Record<string, any>
  // `active: false` means BARRED FROM RUNNING - a declaration that stays
  // in the file and in instances() while being refused a client. It is
  // not a runtime state; voxgig/plugin's lifecycle status is `live`
  // precisely so this key can keep the name it already has.
  active?: boolean
}

export type Descriptor = {
  station: 1
  name: string
  slug: string
  envtoken: string
  version: string
  target: string
  base: string
  server: { name: string, value: string }[]
  auth: { active: boolean, prefix: string, secretname: string }
  entities: Record<string, DescriptorEntity>
  // `options` is the feature's declared key set with typed defaults
  // (§8.5's schema); `transport` its role (§8.4). Both additive, and
  // absent when the SDK does not carry them.
  features: {
    name: string, active: boolean,
    options?: Record<string, any>, transport?: string,
  }[]
}

export type DescriptorEntity = {
  fields: Record<string, { kind: string }>
  ops: Record<string, { points: DescriptorPoint[] }>
}

export type DescriptorPoint = {
  method: string
  path: string
  params: string[]
  select?: Record<string, any>
}

export type StationEvent = {
  t: number
  plugin?: string
  api?: string
  corr?: string
  kind: 'construct' | 'op' | 'http' | 'error' | 'feature' | 'station'
  op?: { entity: string, op: string, outcome: string, durationMs: number }
  http?: {
    method: string, host: string, path: string,
    status: number, durationMs: number, bytes: number
  }
  err?: { code?: string, status?: number, message: string }
  meta?: Record<string, any>
}

export type Binding = {
  // The INSTANCE name (a ref). Keeps the field name for wire
  // compatibility - a consumer that only knows `plugin` keeps working
  // and simply sees instance-grained bindings (§7.3).
  plugin: string
  instance?: string
  base?: string
  placeholder?: string
  secretname?: string
  rung: 'none' | 'R1'
}

export type PluginEntry = {
  name: string
  api: string
  descriptor: Descriptor
  rung: 'none' | 'R1'
  client: any
  warnings: string[]
  secretname?: string
}

export type ResolvedInstance = {
  name: string
  api: string
  active: boolean
  live: boolean
  rung: 'none' | 'R1'
  block: SdkBlock
}
