// @voxgig/station - one control surface for outbound integrations.
//
// THE NODE ENTRY. `index.browser.ts` is the browser condition's entry
// (§2.2, §17 Phase 1): same surface MINUS the file-loading half
// (loadConfig/findConfigFile/configScope) and this registration, which
// is what hands Station the node-only file half without Station itself
// importing a `node:` module.

import { configScope, loadConfig } from './profile'
import { setConfigFileIO } from './Station'

setConfigFileIO({ loadConfig, configScope })

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
