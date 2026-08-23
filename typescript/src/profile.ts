import Fs from 'node:fs'
import Os from 'node:os'
import Path from 'node:path'

import { validname } from '@voxgig/sekreto'

import { secretnameDefault } from './descriptor'
import { StationError } from './error'
import { BLOCK_DEFAULTS } from './shape'
import { StationConfig, SdkBlock } from './types'

// station.json lookup: cwd upward to the repo root, then
// ~/.voxgig/station.json (design §3.5). A repo root is where .git lives;
// with no repo the walk stops at the filesystem root.
export function findConfigFile(from?: string): string | null {
  let dir = Path.resolve(from || process.cwd())
  for (; ;) {
    const candidate = Path.join(dir, 'station.json')
    if (Fs.existsSync(candidate)) { return candidate }
    const atRepoRoot = Fs.existsSync(Path.join(dir, '.git'))
    const parent = Path.dirname(dir)
    if (atRepoRoot || parent === dir) { break }
    dir = parent
  }
  const home = Path.join(Os.homedir(), '.voxgig', 'station.json')
  return Fs.existsSync(home) ? home : null
}

export function loadConfig(from?: string): StationConfig | null {
  const file = findConfigFile(from)
  if (null == file) { return null }
  const text = Fs.readFileSync(file, 'utf8')
  return JSON.parse(text)
}

// Which side of the review boundary the config came from (§6.3).
//
// `package` and `export` are honoured only from REPO-SCOPED config,
// because a user-level file is outside the repo's review boundary and a
// `package` key arriving from it names code to import. Everything else
// in a user-level config still applies - this narrows one key rather
// than distrusting the file.
export function configScope(from?: string): 'repo' | 'user' | 'none' {
  const file = findConfigFile(from)
  if (null == file) { return 'none' }
  const home = Path.join(Os.homedir(), '.voxgig', 'station.json')
  return file === home ? 'user' : 'repo'
}

// Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
// else 'default' (design §3.5 - env vars rank above station.json but
// below open() opts; profile NAME selection follows the same order with
// open() opts winning).
export function selectProfile(optProfile?: string): string {
  if (null != optProfile && '' !== optProfile) { return optProfile }
  const env = process.env.VOXGIG_STATION_PROFILE
  if (null != env && '' !== env) { return env }
  return 'default'
}

// The api half of a ref is the substring before the first `$`, and an
// untagged ref IS an api slug (design §3.4) - which is why the whole
// `plugin` -> `sdk` migration is a key rename and nothing else.
//
// LEXICAL, and that is the point: under the old free-form identity
// which api an instance used was itself a merged value, so the merge
// could not be a flat pass over both maps and a port that got the
// phasing wrong silently picked another api's defaults (§3.3).
export function refapi(ref: string): string {
  const at = String(ref).indexOf('$')
  return -1 === at ? String(ref) : String(ref).slice(0, at)
}

export type ResolvedProfile = {
  name: string
  providers: any[]
  // The api-level defaults in effect for this profile, base ⊕ overlay
  // per api slug. A REPORT, not an input to the instance merge below -
  // collapsing each namespace first and composing at the end is the
  // exact algorithm §3.3 forbids.
  api: Record<string, SdkBlock>
  // Instances, keyed by ref. An `api` block declares no instance of its
  // own (§3.1), so it never creates an entry here.
  sdk: Record<string, SdkBlock>
}

// Shallow merge, per key, left to right - each source over the one
// before it. Declared rather than assumed: plugin's library default is
// a deep map merge, and an allowlist that widens because two precedence
// levels merged is the failure this rule exists to prevent
// (station-and-plugin.md §2.5). The visible consequence: an overlay's
// `policy` REPLACES the base's entirely rather than merging `hosts`
// into it. That is also the safer reading for an allowlist.
function shallow(...sources: any[]): any {
  const out: any = {}
  for (const src of sources) {
    if (null == src || 'object' !== typeof src || Array.isArray(src)) { continue }
    for (const k of Object.keys(src)) { out[k] = src[k] }
  }
  return out
}

// Merge the base profile ('default') with the selected overlay.
//
// §3.3's total order, for the two block levels - lowest precedence
// first:
//
//   base.api[<api>] ⊕ base.sdk[<ref>] ⊕ overlay.api[<api>] ⊕ overlay.sdk[<ref>]
//
// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY. A `prod` api-level
// `base` beats a `default` instance-level `base`, because that is what
// an environment overlay is for; within one profile the instance beats
// the api default, because that is what an instance is for.
//
// THIS IS ONE FLAT LEFT-TO-RIGHT MERGE AND MUST NOT BE REORGANIZED INTO
// "collapse each namespace, then put instance over api". Collapsing
// first computes (base.api ⊕ overlay.api) and (base.sdk ⊕ overlay.sdk)
// and then lets EVERY instance value beat EVERY api value - the exact
// opposite. A production `api.stripe.policy` would then fail to
// override a default profile's `sdk.stripe$test.policy`, silently
// keeping the wider allowlist in production.
//
// `secrets.providers` replaces wholesale, never merges (§3.5, §5.2):
// chain order decides which store wins, so a positional merge would be
// actively dangerous.
export function resolveProfile(
  config: StationConfig | null, profileName: string
): ResolvedProfile {
  const profiles = config?.profiles || {}
  const base: any = profiles['default'] || {}
  const overlay: any = 'default' === profileName
    ? {} : (profiles[profileName] || {})

  const providers = overlay.secrets?.providers ?? base.secrets?.providers ??
    [{ kind: 'env' }]

  const api: Record<string, SdkBlock> = {}
  for (const slug of sortedkeys(base.api, overlay.api)) {
    api[slug] = shallow(base.api?.[slug], overlay.api?.[slug])
  }

  // An api block declares no instance, so the ref set comes from the
  // two `sdk` maps alone.
  const sdk: Record<string, SdkBlock> = {}
  for (const ref of sortedkeys(base.sdk, overlay.sdk)) {
    const a = refapi(ref)
    const merged = shallow(
      base.api?.[a],
      base.sdk?.[ref],
      overlay.api?.[a],
      overlay.sdk?.[ref],
    )

    // Defaults are applied ONCE, to the fully merged instance, and this
    // is the rule §4.2's normalization must not be confused with. Had
    // the overlay block carried a synthesized `active: true` into the
    // merge, a one-key environment override would silently re-enable an
    // integration the base declared `active: false` - live in
    // production despite being declared inactive. The `instance` corpus
    // section carries exactly this case.
    for (const k of Object.keys(BLOCK_DEFAULTS)) {
      if (undefined === merged[k]) { merged[k] = BLOCK_DEFAULTS[k]() }
    }

    sdk[ref] = merged
  }

  checksecrets(sdk, profileName)

  return { name: profileName, providers, api, sdk }
}

// A configured secret name sekreto would reject is caught at profile
// load, not first request (§14 station_secret_name) - and then the
// derived names are checked for uniqueness, because envtoken is LOSSY.
//
// It collapses any run of non-alphanumerics to `_`, so `$` and `-` are
// indistinguishable downstream: the ref `stripe$test` and an untagged
// instance of an api slugged `stripe-test` both derive
// `stripe_test.apikey`. That pairing is the realistic one rather than a
// contrived one, because api slugs are hyphenated by construction - so
// a fleet with both a `stripe-test` api and a `test` instance of
// `stripe` collides by default. Since the resolution cache is keyed by
// secret name (§5.3), the second instance would silently receive the
// first's value.
//
// Two instances that EXPLICITLY name the same secret are not a
// collision - that is the shared-key case the api-level `secret` exists
// for, and saying so out loud is how you ask for it.
function checksecrets(
  sdk: Record<string, SdkBlock>, profileName: string
): void {
  const refs = Object.keys(sdk).sort()

  for (const ref of refs) {
    const name = sdk[ref].secret
    if (null != name && !validname(name)) {
      throw new StationError('station_secret_name',
        'profile "' + profileName + '" sdk "' + ref +
        '": secret name rejected by sekreto: ' + JSON.stringify(name))
    }
  }

  const seen = new Map<string, { ref: string, derived: boolean }>()
  for (const ref of refs) {
    const written = sdk[ref].secret
    const derived = null == written || '' === written
    const name = derived ? secretnameDefault(ref) : (written as string)

    const prior = seen.get(name)
    if (undefined !== prior && (derived || prior.derived)) {
      throw new StationError('station_secret_collision',
        'profile "' + profileName + '": instances "' + prior.ref + '" and "' +
        ref + '" both resolve to secret name "' + name +
        '", so they would share one credential; name it explicitly on ' +
        'each, or at the api level to share it deliberately (§5.1)')
    }
    if (undefined === prior) { seen.set(name, { ref, derived }) }
  }
}

function sortedkeys(...maps: any[]): string[] {
  const keys = new Set<string>()
  for (const m of maps) {
    if (null == m || 'object' !== typeof m || Array.isArray(m)) { continue }
    for (const k of Object.keys(m)) { keys.add(k) }
  }
  return Array.from(keys).sort()
}
