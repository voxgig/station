// RUN: npm test
//
// The station conformance suite: the pure-contract half of the design's
// §13 corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery
// (inject, order, event correlation) live in the integration suites
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present.

const { before, describe, test } = require('node:test')

const { envkey } = require('@voxgig/sekreto-js')

const {
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
} = require('../src/descriptor')
const { isKnownCode } = require('../src/error')
const { placeholderFor } = require('../src/secrets')
const { resolveProfile } = require('../src/profile')
const { omnihome, specfile } = require('../src/omnihome')

// omni is a sibling checkout, not a published package (yet).
const omni = require(omnihome() + '/javascript/src')

// Spec nulls arrive as omni's NULLMARK sentinel; restore them so each
// driver sees what the spec means.
const denull = (v) => {
  if (omni.NULLMARK === v) { return null }
  if (Array.isArray(v)) { return v.map(denull) }
  if (null != v && 'object' === typeof v) {
    const out = {}
    for (const k of Object.keys(v)) { out[k] = denull(v[k]) }
    return out
  }
  return v
}

describe('station-conform', () => {
  let R

  before(async () => {
    const runner = await omni.makeRunner(specfile())
    R = await runner('station')
  })

  test('secretname', async () => {
    await R.runset(R.spec.secretname, (vin) => {
      const secretname = secretnameDefault(vin.slug)
      return {
        envtoken: envtoken(vin.slug),
        secretname,
        envkey: envkey(secretname),
      }
    })
  })

  test('placeholder', async () => {
    await R.runset(R.spec.placeholder, (slug) => placeholderFor(slug))
  })

  test('descriptor', async () => {
    await R.runset(R.spec.descriptor, (vin) =>
      normalizeDescriptor(vin.config, vin.feature).descriptor)
  })

  test('descriptorwarnings', async () => {
    await R.runset(R.spec.descriptorwarnings, (vin) =>
      normalizeDescriptor(vin.config, vin.feature).warnings.length)
  })

  test('canonical', async () => {
    await R.runset(R.spec.canonical, (vin) => canonicalSerialize(denull(vin)))
  })

  // The §3.3 merge, and the whole of this port's profile contract.
  //
  // The `profile` section is NOT run here: it pins the pre-Stage-1
  // `plugin` grammar, which this port no longer speaks. It stays in the
  // corpus for the ports that have not crossed the rename yet and is
  // deleted when the last one does - see spec/README.md. Everything it
  // pins is restated below in the sdk/api grammar.
  test('instance', async () => {
    await R.runset(R.spec.instance, (vin) =>
      resolveProfile(denull(vin.config), vin.profile))
  })

  test('errors', async () => {
    await R.runset(R.spec.errors, (code) => isKnownCode(code))
  })
})
