// RUN: npm test
//
// The station conformance suite: the pure-contract half of the design's
// §13 corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery
// (inject, order, event correlation) live in the integration suites
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present.

const Fs = require('node:fs')
const { deepStrictEqual, ok } = require('node:assert')
const { before, describe, test } = require('node:test')

const { envkey } = require('@voxgig/sekreto-js')

const {
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
} = require('../src/descriptor')
const { isKnownCode } = require('../src/error')
const {
  checkpin,
  featuresources,
  mergefeatures,
  resolveorder,
} = require('../src/feature')
const { placeholderFor } = require('../src/secrets')
const { resolveProfile } = require('../src/profile')
const { normalizeConfig, validateConfig } = require('../src/shape')
const { instanceRef } = require('../src/Station')
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

// One driver per section this port RUNS, keyed by the corpus section
// name - the tests below are REGISTERED from this table, so a section
// listed here cannot silently not run, and the completeness guard
// closes the other direction.
const DRIVERS = {
  secretname: (vin) => {
    const secretname = secretnameDefault(vin.slug)
    return {
      envtoken: envtoken(vin.slug),
      secretname,
      envkey: envkey(secretname),
    }
  },

  placeholder: (slug) => placeholderFor(slug),

  descriptor: (vin) =>
    normalizeDescriptor(vin.config, vin.feature).descriptor,

  descriptorwarnings: (vin) =>
    normalizeDescriptor(vin.config, vin.feature).warnings.length,

  canonical: (vin) => canonicalSerialize(denull(vin)),

  // Normalize, then validate (design §4.2). The entry is a RAW config
  // in, and either the normalized output or the expected error out -
  // the two steps are one pipeline and a port that splits them is free
  // to validate the wrong form.
  config: (vin) => validateConfig(normalizeConfig(denull(vin))),

  // The §3.3 merge, and the whole of this port's profile contract.
  instance: (vin) => resolveProfile(denull(vin.config), vin.profile),

  // §8's pure half (design §10.1): the three-level merge with its depth
  // boundary, and the §8.4 order resolution. One driver, two entry
  // shapes - `merged` selects the resolver, anything else the merge -
  // because a port that guessed from looser cues would run the wrong
  // subject on a mistyped entry.
  feature: (vin) => {
    if (null != vin.merged) {
      const ordered = resolveorder(denull(vin.merged))
      checkpin(ordered)
      return ordered.map((o) => o.name)
    }
    return mergefeatures(featuresources(
      denull(vin.base), denull(vin.overlay), vin.api, vin.ref))
  },

  // §6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
  // rather than driver-shaped even though it decides a registry key.
  instanceref: (vin) => instanceRef(vin.api, vin.opts),

  errors: (code) => isKnownCode(code),
}

// The sections this port deliberately does NOT run, with the reason -
// an entry here is a decision, not an omission. Currently empty: this
// port runs every section the corpus carries.
const PENDING = {}

describe('station-conform', () => {
  let R

  before(async () => {
    const runner = await omni.makeRunner(specfile())
    R = await runner('station')
  })

  // Section completeness: the sections run plus the explicit PENDING
  // list must exactly cover what spec/station.json carries. A section
  // added to the corpus and not picked up here fails loudly instead of
  // silently not running.
  test('sections-covered', () => {
    const spec = JSON.parse(Fs.readFileSync(specfile(), 'utf8'))
    const present = Object.keys(spec.primary.station).sort()
    const covered = Object.keys(DRIVERS).concat(Object.keys(PENDING)).sort()
    deepStrictEqual(covered, present)
  })

  for (const section of Object.keys(DRIVERS)) {
    test(section, async () => {
      ok(null != R.spec[section], 'corpus section missing: ' + section)
      await R.runset(R.spec[section], DRIVERS[section])
    })
  }
})
