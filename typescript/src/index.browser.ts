// @voxgig/station - one control surface for outbound integrations.
//
// THE BROWSER ENTRY (§2.2, §17 Phase 1), selected by the `browser`
// condition in package.json `exports`. The same surface as `index.ts`
// MINUS the file-loading half - `loadConfig`, `findConfigFile` and
// `configScope` are node-only (`profile.ts`, the one module in this
// package with top-level `node:` imports) and are simply not here, so
// this entry's module graph pulls no `node:` builtin
// (`test/browser.test.ts` walks the compiled graph and asserts it).
//
// `Station.open()` on this entry takes `config` as an OBJECT - the
// pre-existing explicit-config path, which skips file loading entirely.
// With no `config` at all it behaves exactly as node does when no
// station.json exists: null config, repo-scoped. The ConfigFileIO seam
// stays unregistered here; a host that genuinely has a config store can
// register its own through `setConfigFileIO`.
//
// §2.2's honesty note stands: in the browser R1/R2 isolation does not
// exist - an injected credential is readable by page code and DevTools
// - so browser station is observability-only with app-held credentials
// until a same-origin proxy endpoint exists.

export { Station, instanceRef, setConfigFileIO } from './Station'
export type { ConfigFileIO } from './Station'
export { provide, factoryFor, provided, resetFactories } from './factory'
export type { Factory, FactoryEntry } from './factory'
export {
  DEFAULT_EXPORT, camelify, checkPackage, factoryFromModule, loadAsync, loadSync,
} from './loader'
export { adapterFeature, featureBinding } from './adapter'
export type { FeatureBinding } from './adapter'
export { StationError } from './error'
export {
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
} from './descriptor'
export { placeholderFor } from './secrets'
export { refapi, resolveProfile, selectProfile } from './profilecore'
export type { ResolvedProfile } from './profilecore'
export {
  BLOCK_DEFAULTS, MERGE_SENSITIVE, PROFILE_DEFAULTS,
  configShape, normalizeConfig, validateConfig,
} from './shape'
export type {
  Binding,
  Descriptor,
  PolicyBlock,
  Profile,
  ResolvedInstance,
  SdkBlock,
  StationConfig,
  StationEvent,
  StationOptions,
} from './types'
