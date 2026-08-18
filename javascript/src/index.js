// @voxgig/station-js - one control surface for outbound integrations.
//
// A port of typescript/src/index.ts, which is canonical.

const { Station } = require('./Station')
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
  findConfigFile,
  loadConfig,
  resolveProfile,
  selectProfile,
} = require('./profile')

module.exports = {
  Station,
  adapterFeature,
  featureBinding,
  StationError,
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
  placeholderFor,
  findConfigFile,
  loadConfig,
  resolveProfile,
  selectProfile,
}
