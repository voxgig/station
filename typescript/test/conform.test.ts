// RUN: npm test
//
// The station conformance suite: the pure-contract half of the design's
// §13 corpus, from spec/station.json, through voxgig/omni - the same
// file every future port runs. Sections that need live SDK machinery
// (inject, order, event correlation) live in the integration suites
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present.

import { before, describe, test } from 'node:test'

import { envkey } from '@voxgig/sekreto'

import {
  canonicalSerialize,
  envtoken,
  normalizeDescriptor,
  secretnameDefault,
} from '../src/descriptor'
import { isKnownCode } from '../src/error'
import { placeholderFor } from '../src/secrets'
import { resolveProfile } from '../src/profile'
import { normalizeConfig, validateConfig } from '../src/shape'
import { omnihome, specfile } from '../src/omnihome'

// omni is a sibling checkout, not a published package (yet).
// eslint-disable-next-line @typescript-eslint/no-var-requires
const omni = require(omnihome() + '/typescript/dist/src')

// Spec nulls arrive as omni's NULLMARK sentinel; restore them so each
// driver sees what the spec means.
const denull = (v: any): any => {
  if (omni.NULLMARK === v) { return null }
  if (Array.isArray(v)) { return v.map(denull) }
  if (null != v && 'object' === typeof v) {
    const out: any = {}
    for (const k of Object.keys(v)) { out[k] = denull(v[k]) }
    return out
  }
  return v
}

describe('station-conform', () => {
  let R: any

  before(async () => {
    const runner = await omni.makeRunner(specfile())
    R = await runner('station')
  })

  test('secretname', async () => {
    await R.runset(R.spec.secretname, (vin: any) => {
      const secretname = secretnameDefault(vin.slug)
      return {
        envtoken: envtoken(vin.slug),
        secretname,
        envkey: envkey(secretname),
      }
    })
  })

  test('placeholder', async () => {
    await R.runset(R.spec.placeholder, (slug: any) => placeholderFor(slug))
  })

  test('descriptor', async () => {
    await R.runset(R.spec.descriptor, (vin: any) =>
      normalizeDescriptor(vin.config, vin.feature).descriptor)
  })

  test('descriptorwarnings', async () => {
    await R.runset(R.spec.descriptorwarnings, (vin: any) =>
      normalizeDescriptor(vin.config, vin.feature).warnings.length)
  })

  test('canonical', async () => {
    await R.runset(R.spec.canonical, (vin: any) => canonicalSerialize(denull(vin)))
  })

  // Normalize, then validate (design §4.2). The entry is a RAW config
  // in, and either the normalized output or the expected error out -
  // the two steps are one pipeline and a port that splits them is free
  // to validate the wrong form.
  test('config', async () => {
    await R.runset(R.spec.config, (vin: any) =>
      validateConfig(normalizeConfig(denull(vin))))
  })

  // The §3.3 merge, and the whole of this port's profile contract.
  //
  // The `profile` section is NOT run here: it pins the pre-Stage-1
  // `plugin` grammar, which this port no longer speaks. It stays in the
  // corpus for the ports that have not crossed the rename yet and is
  // deleted when the last one does - see spec/README.md. Everything it
  // pins is restated below in the sdk/api grammar.
  test('instance', async () => {
    await R.runset(R.spec.instance, (vin: any) =>
      resolveProfile(denull(vin.config), vin.profile))
  })

  test('errors', async () => {
    await R.runset(R.spec.errors, (code: any) => isKnownCode(code))
  })
})
