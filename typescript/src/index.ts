// @voxgig/station - one control surface for outbound integrations.

export { Station } from './Station'
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
  findConfigFile, loadConfig, refapi, resolveProfile, selectProfile,
} from './profile'
export type { ResolvedProfile } from './profile'
export {
  BLOCK_DEFAULTS, MERGE_SENSITIVE, PROFILE_DEFAULTS,
  configShape, normalizeConfig, validateConfig,
} from './shape'
export type {
  Binding,
  Descriptor,
  Profile,
  SdkBlock,
  StationConfig,
  StationEvent,
  StationOptions,
} from './types'
