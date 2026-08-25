// @voxgig/station-js - one control surface for outbound integrations.
//
// A port of typescript/src/index.ts, which is canonical. Canonical used
// to carry a second, browser-only entry that this port never had;
// station is server-side only and that entry is gone, so the two are
// structurally the same shape again.

const { Station, checkInstanceName, checkInstanceTag, instanceRef } =
  require('./Station')
const { factoryFor, provide, provided, resetFactories } = require('./factory')
const {
  DEFAULT_EXPORT, camelify, checkPackage, factoryFromModule, loadAsync,
  loadSync,
} = require('./loader')
const { adapterFeature, featureBinding } = require('./adapter')
const { StationError } = require('./error')
const {
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
} = require('./descriptor')
const { placeholderFor } = require('./secrets')
const {
  configScope,
  findConfigFile,
  loadConfig,
  refapi,
  resolveProfile,
  selectProfile,
} = require('./profile')
const {
  BLOCK_DEFAULTS,
  MERGE_SENSITIVE,
  PROFILE_DEFAULTS,
  configShape,
  normalizeConfig,
  validateConfig,
} = require('./shape')
const {
  BAND_DEFAULT,
  BAND_STATION,
  BAND_TEST,
  RESERVED_KEYS,
  checkfeatures,
  checkpin,
  composefeatures,
  defaultband,
  featuresources,
  mergefeatures,
  resolveorder,
} = require('./feature')

module.exports = {
  Station,
  checkInstanceName,
  checkInstanceTag,
  instanceRef,
  factoryFor,
  provide,
  provided,
  resetFactories,
  DEFAULT_EXPORT,
  camelify,
  checkPackage,
  factoryFromModule,
  loadAsync,
  loadSync,
  adapterFeature,
  featureBinding,
  StationError,
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
  placeholderFor,
  configScope,
  findConfigFile,
  loadConfig,
  refapi,
  resolveProfile,
  selectProfile,
  BLOCK_DEFAULTS,
  MERGE_SENSITIVE,
  PROFILE_DEFAULTS,
  configShape,
  normalizeConfig,
  validateConfig,
  BAND_DEFAULT,
  BAND_STATION,
  BAND_TEST,
  RESERVED_KEYS,
  checkfeatures,
  checkpin,
  composefeatures,
  defaultband,
  featuresources,
  mergefeatures,
  resolveorder,
}
