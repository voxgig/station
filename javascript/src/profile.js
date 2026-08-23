// A port of typescript/src/profile.ts, which is canonical.

const Fs = require('node:fs')
const Os = require('node:os')
const Path = require('node:path')

const { validname } = require('@voxgig/sekreto-js')

const { secretnameDefault } = require('./descriptor')
const { StationError } = require('./error')

// station.json lookup: cwd upward to the repo root, then
// ~/.voxgig/station.json (design §3.5). A repo root is where .git lives;
// with no repo the walk stops at the filesystem root.
function findConfigFile(from) {
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

function loadConfig(from) {
  const file = findConfigFile(from)
  if (null == file) { return null }
  const text = Fs.readFileSync(file, 'utf8')
  return JSON.parse(text)
}

// Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
// else 'default' (design §3.5 - env vars rank above station.json but
// below open() opts; profile NAME selection follows the same order with
// open() opts winning).
// The block-level defaults table. `active` carries the timing rule:
// applied AFTER the merge, never before (§3.3, §4.2).
const BLOCK_DEFAULTS = {
  active: () => true,
  feature: () => ({}),
}

function selectProfile(optProfile) {
  if (null != optProfile && '' !== optProfile) { return optProfile }
  const env = process.env.VOXGIG_STATION_PROFILE
  if (null != env && '' !== env) { return env }
  return 'default'
}

// The api half of a ref is the substring before the first `$`, and an
// untagged ref IS an api slug (design §3.4). LEXICAL, and that is the
// point: under the old free-form identity which api an instance used
// was itself a merged value, so a port that got the phasing wrong
// silently picked another api's defaults (§3.3).
function refapi(ref) {
  const at = String(ref).indexOf('$')
  return -1 === at ? String(ref) : String(ref).slice(0, at)
}

// Shallow merge, per key, left to right - each source over the one
// before it. An overlay's `policy` REPLACES the base's entirely rather
// than merging `hosts` into it; an allowlist that widens because two
// precedence levels merged is the failure this rule prevents.
function shallow(...sources) {
  const out = {}
  for (const src of sources) {
    if (null == src || 'object' !== typeof src || Array.isArray(src)) { continue }
    for (const k of Object.keys(src)) { out[k] = src[k] }
  }
  return out
}

function sortedkeys(...maps) {
  const keys = new Set()
  for (const m of maps) {
    if (null == m || 'object' !== typeof m || Array.isArray(m)) { continue }
    for (const k of Object.keys(m)) { keys.add(k) }
  }
  return Array.from(keys).sort()
}

// Merge the base profile ('default') with the selected overlay.
//
// §3.3's total order for the two block levels, lowest precedence first:
//
//   base.api[<api>] ⊕ base.sdk[<ref>] ⊕ overlay.api[<api>] ⊕ overlay.sdk[<ref>]
//
// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
// LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
// namespace, then put instance over api" - that lets every instance
// value beat every api value, so a production `api.stripe.policy` would
// fail to override a default profile's `sdk.stripe$test.policy`,
// silently keeping the wider allowlist in production.
//
// `secrets.providers` replaces wholesale, never merges (§3.5, §5.2).
function resolveProfile(config, profileName) {
  const profiles = (config && config.profiles) || {}
  const base = profiles['default'] || {}
  const overlay = 'default' === profileName ? {} : (profiles[profileName] || {})

  const providers = overlay.secrets?.providers ?? base.secrets?.providers ??
    [{ kind: 'env' }]

  // The api-level defaults in effect for this profile. A REPORT, not an
  // input to the instance merge below.
  const api = {}
  for (const slug of sortedkeys(base.api, overlay.api)) {
    api[slug] = shallow(base.api?.[slug], overlay.api?.[slug])
  }

  // An api block declares no instance of its own (§3.1), so the ref set
  // comes from the two `sdk` maps alone.
  const sdk = {}
  for (const ref of sortedkeys(base.sdk, overlay.sdk)) {
    const a = refapi(ref)
    const merged = shallow(
      base.api?.[a], base.sdk?.[ref], overlay.api?.[a], overlay.sdk?.[ref])

    // Defaults are applied ONCE, to the fully merged instance. Had the
    // overlay block carried a synthesized `active: true` into the
    // merge, a one-key environment override would silently re-enable an
    // integration the base declared inactive.
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
// DERIVED names are checked for uniqueness, because envtoken is lossy:
// it collapses any run of non-alphanumerics to `_`, so `stripe$test` and
// an untagged instance of a `stripe-test` api both derive
// `stripe_test.apikey` and would silently share one credential.
//
// Two instances that EXPLICITLY name one secret are not a collision -
// that is the shared-key case the api-level `secret` exists for.
function checksecrets(sdk, profileName) {
  const refs = Object.keys(sdk).sort()

  for (const ref of refs) {
    const name = sdk[ref].secret
    if (null != name && !validname(name)) {
      throw new StationError('station_secret_name',
        'profile "' + profileName + '" sdk "' + ref +
        '": secret name rejected by sekreto: ' + JSON.stringify(name))
    }
  }

  const seen = new Map()
  for (const ref of refs) {
    const written = sdk[ref].secret
    const derived = null == written || '' === written
    const name = derived ? secretnameDefault(ref) : written

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

module.exports = {
  BLOCK_DEFAULTS,
  findConfigFile,
  refapi,
  loadConfig,
  resolveProfile,
  selectProfile,
}
