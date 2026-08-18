// Shared station types. Descriptor and StationEvent shapes are pinned by
// the conformance corpus (spec/station.json) - evolve them additively.

export type StationOptions = {
  profile?: string
  proxy?: 'auto' | 'off' | 'require' | string
  folder?: string
  config?: StationConfig | null
}

// station.json shape (profiles carry sekreto ProviderSpecs verbatim).
export type StationConfig = {
  station: number
  profiles?: Record<string, Profile>
}

export type Profile = {
  secrets?: { providers?: any[] }
  plugin?: Record<string, PluginProfile>
}

export type PluginProfile = {
  base?: string
  secret?: string
  resolve?: 'library' | 'proxy'
  policy?: { hosts?: string[] }
  active?: boolean
}

// Descriptor v1 (design §4): a view over the SDK's embedded config,
// normalized - never a second model.
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
  features: { name: string, active: boolean }[]
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

// StationEvent v1 (design §6). Unknown fields are ignored by consumers.
export type StationEvent = {
  t: number
  plugin?: string
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

// What registration hands back to the adapter (design §3 item 1).
export type Binding = {
  plugin: string
  base?: string
  placeholder?: string
  secretname?: string
  rung: 'none' | 'R1'
}

export type PluginEntry = {
  slug: string
  descriptor: Descriptor
  rung: 'none' | 'R1'
  client: any
  warnings: string[]
}
