// @voxgig/station - one control surface for outbound integrations.
//
// THE ONLY ENTRY. There was a second, `index.browser.ts`, selected by a
// `browser` condition: the same surface minus the file-loading half, so
// no `node:` builtin was reachable from it. Station is server-side only,
// so that entry, the `ConfigFileIO` seam it needed and the graph-walk
// test that guarded it are all gone.

export { Station, instanceRef } from './Station'
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
export {
  configScope, findConfigFile, loadConfig, refapi, resolveProfile,
  selectProfile,
} from './profile'
export type { ResolvedProfile } from './profile'
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
