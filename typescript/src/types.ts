// Shared station types. Descriptor and StationEvent shapes are pinned by
// the conformance corpus (spec/station.json) - evolve them additively.

export type StationOptions = {
  profile?: string
  proxy?: 'auto' | 'off' | 'require' | string
  folder?: string
  config?: StationConfig | null
  // §6.3: disables the loader outright. Only self-registered and
  // explicitly provided factories are used.
  load?: boolean
  // Set when the config came from ~/.voxgig/station.json rather than
  // from inside the repo. A user-level file is outside the repo's
  // review boundary, so a `package` key arriving from it is IGNORED
  // WITH A WARNING rather than imported - everything else in it still
  // applies.
  repoScoped?: boolean
}

// station.json shape (profiles carry sekreto ProviderSpecs verbatim).
export type StationConfig = {
  station: number
  profiles?: Record<string, Profile>
}

export type Profile = {
  secrets?: { providers?: any[] }
  feature?: Record<string, any>
  // Keyed by api slug: defaults inherited by every instance of that
  // api, declaring no instance of its own (design §3.1).
  api?: Record<string, SdkBlock>
  // Keyed by REF (`api$tag`, or bare `api` for the untagged instance).
  // This replaces `plugin`, which is REMOVED rather than aliased (§3.4)
  // - a deprecated alias would be a second grammar for one concept in
  // 17 ports. An untagged ref is an api slug, so every existing block
  // means exactly what it meant before under the new key.
  sdk?: Record<string, SdkBlock>
}

// The same eight keys in both block positions. The two differ in what
// they KEY, not in what they hold, which is why the two spec objects in
// config-shape.json are identical and a guard test asserts it (§3.1).
export type SdkBlock = {
  package?: string
  export?: string
  base?: string
  secret?: string
  resolve?: 'library' | 'proxy'
  policy?: { hosts?: string[] }
  feature?: Record<string, any>
  options?: Record<string, any>
  // `active: false` means BARRED FROM RUNNING - a declaration that stays
  // in the file and in instances() while being refused a client. It is
  // not a runtime state; voxgig/plugin's lifecycle status is `live`
  // precisely so this key can keep the name it already has.
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
  // The INSTANCE name (§7.3). Keeps its name, so a consumer that only
  // knows `plugin` keeps working - it simply sees instance-grained
  // events, which is what it wants at 20 SDKs anyway.
  plugin?: string
  // The api slug, for grouping. ADDITIVE, so station.md §8.6's wire
  // compatibility rule holds.
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

// What registration hands back to the adapter (design §3 item 1).
export type Binding = {
  // The INSTANCE name (a ref). Keeps the field name for wire
  // compatibility - a consumer that only knows `plugin` keeps working
  // and simply sees instance-grained bindings (§7.3).
  plugin: string
  // The api slug, for grouping. Additive.
  instance?: string
  base?: string
  placeholder?: string
  // The instance's EFFECTIVE secret name, and the authority for it
  // (§7.4). A descriptor is shared by every instance of one api and so
  // cannot hold two different instance-derived names; the descriptor's
  // own `auth.secretname` stays the api-level default, which is
  // documentation.
  secretname?: string
  rung: 'none' | 'R1'
}

export type PluginEntry = {
  // The instance name - the registry key (§7.1).
  name: string
  // The api slug. One descriptor per api is shared by every instance of
  // it, so this is what `descriptorOf` and the cache key on.
  api: string
  descriptor: Descriptor
  rung: 'none' | 'R1'
  client: any
  warnings: string[]
  // The instance's effective secret name, mirroring Binding.secretname
  // so `plugins()` can report it without re-deriving.
  secretname?: string
}

// A declared instance, resolved (§6.1's `instances()`).
export type ResolvedInstance = {
  name: string
  api: string
  // `active: false` means BARRED FROM RUNNING - declared, visible, and
  // refused a client. Not a runtime state.
  active: boolean
  // Exactly plugin's `status == "live"`; the two answer different
  // questions and the answers differ routinely, since a lazily-started
  // instance is active and not yet live.
  live: boolean
  rung: 'none' | 'R1'
  block: SdkBlock
}
