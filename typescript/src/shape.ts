/* The config grammar, as data (design §4).
 *
 * TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
 *
 * struct drops the unexpected-key check for a map whose spec node ends
 * up empty - "an empty spec object means the object can be open". An
 * optional key is `['$ONE','$NIL', spec]`, and when the data does not
 * carry that key the validator REMOVES it from the spec node. So a
 * block whose keys are all optional degenerates into an open map
 * exactly when the data has none of them, and `{"solar": {"bass": 1}}`
 * validates clean - the one property the whole exercise is for,
 * silently absent in the one case that matters.
 *
 * So: normalizeConfig materializes every documented default, and
 * validateConfig then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
 * After normalization every container is present, so the shape can
 * require them, so unexpected-key detection is live at every level and
 * every error names its path. */

import { clone, validate } from '@voxgig/struct'
import { validname } from '@voxgig/sekreto'

import { CONFIG_SHAPE } from './config-shape'
import { StationError } from './error'
import { envtoken } from './descriptor'

// ---------------------------------------------------------------------
// The defaults table - ONE table, two callers
// ---------------------------------------------------------------------

/** Profile-level containers. Safe to materialize early either way:
 * they are containers, and a missing one merges as empty regardless. */
export const PROFILE_DEFAULTS: { [k: string]: () => any } = {
  secrets: () => ({ providers: [{ kind: 'env' }] }),
  api: () => ({}),
  sdk: () => ({}),
  feature: () => ({}),
}

/** Block-level. `feature` is a container and safe early.
 *
 * `active` IS NOT, and that is the whole timing rule: a default
 * synthesized into an OVERLAY block overwrites the base's real value
 * and silently reactivates an integration the base deliberately barred
 * (§3.3). So the two consumers read this same table at different
 * moments - validateConfig before, to every block, because a block with
 * no present keys is an open map; the resolver AFTER, to the merged
 * instance, because an absent key must stay absent through the merge. */
export const BLOCK_DEFAULTS: { [k: string]: () => any } = {
  active: () => true,
  feature: () => ({}),
}

/** The one block key carrying the timing rule. Named rather than
 * inferred, so a reader does not have to work out which of the two it
 * is, and so a port can assert it. */
export const MERGE_SENSITIVE = ['active']

// ---------------------------------------------------------------------
// normalizeConfig
// ---------------------------------------------------------------------

/** Materialize every documented default, DEFENSIVELY: a node that is
 * not the kind it expects is left alone for validate to reject with a
 * proper message. Pure data-in/data-out, which is what makes it
 * portable to 22 languages and expressible in the corpus.
 *
 * THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE. */
export function normalizeConfig(raw: any): any {
  if (!ismap(raw)) { return raw }
  const out: any = { ...raw }

  if (undefined === out.station) { out.station = 1 }
  if (undefined === out.profiles) { out.profiles = {} }
  if (!ismap(out.profiles)) { return out }

  const profiles: any = {}
  for (const pname of Object.keys(out.profiles)) {
    const p = out.profiles[pname]
    if (!ismap(p)) { profiles[pname] = p; continue }
    const prof: any = { ...p }

    for (const k of Object.keys(PROFILE_DEFAULTS)) {
      if (undefined === prof[k]) { prof[k] = PROFILE_DEFAULTS[k]() }
    }
    // A `secrets` written without `providers` still gets the chain.
    if (ismap(prof.secrets) && undefined === prof.secrets.providers) {
      prof.secrets = { ...prof.secrets, providers: [{ kind: 'env' }] }
    }
    prof.feature = normfeatures(prof.feature)

    for (const bkey of ['api', 'sdk']) {
      if (!ismap(prof[bkey])) { continue }
      const blocks: any = {}
      for (const ref of Object.keys(prof[bkey])) {
        const b = prof[bkey][ref]
        if (!ismap(b)) { blocks[ref] = b; continue }
        const block: any = { ...b }
        for (const k of Object.keys(BLOCK_DEFAULTS)) {
          if (undefined === block[k]) { block[k] = BLOCK_DEFAULTS[k]() }
        }
        block.feature = normfeatures(block.feature)
        blocks[ref] = block
      }
      prof[bkey] = blocks
    }

    profiles[pname] = prof
  }
  out.profiles = profiles
  return out
}

/** Per feature entry, at every level: `active` -> true.
 *
 * A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
 * own default is `active: false` for all but `log`, and
 * `{"retry": {"retries": 3}}` plainly means "retry, with three
 * attempts". It also keeps the feature map closed, for the same reason
 * every other block needs one present key.
 *
 * Defensive like the rest: a non-map is returned untouched for validate
 * to reject by path. */
function normfeatures(f: any): any {
  if (!ismap(f)) { return f }
  const out: any = {}
  for (const name of Object.keys(f)) {
    const e = f[name]
    out[name] = ismap(e) && undefined === e.active ? { ...e, active: true } : e
  }
  return out
}

// ---------------------------------------------------------------------
// validateConfig
// ---------------------------------------------------------------------

/** `spec/config-shape.json`, §4.3 verbatim, through the shipped mirror.
 * Every validate gets a CLONE: struct's validate consumes the spec it
 * walks (it deletes satisfied `$ONE` branches as it goes), so handing it
 * the module constant twice would validate the second config against a
 * spec the first had already eaten. */
export function configShape(): any {
  return clone(CONFIG_SHAPE)
}

/** Credential-shaped keys (§5.2). `secret` is here AND is the one
 * exempt key - see secretvalue below; a blanket deny would reject the
 * very mechanism that keeps values out of the file. */
const CREDENTIAL_KEYS = [
  'apikey', 'auth', 'authorization', 'token',
  'secret', 'password', 'credential', 'bearer',
]

/** The suffix rule catches `access_key`, `X-Api-Token` and friends in
 * one rule rather than a growing list of spellings. */
const CREDENTIAL_SUFFIX = ['_KEY', '_TOKEN', '_SECRET', '_PASSWORD']

/** §5.2's backstop, and it is stated as one rather than as a grammar.
 * `validname()` is a NAME grammar, not a credential filter: it rejects
 * uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
 * credential formats - but a lowercase hex token passes it cleanly. A
 * character class cannot tell a name from a secret.
 *
 * Derived names break on every separator (`voxgig_solardemo.apikey`
 * runs 6/9/6) and a hand-written name for a human to read does too; a
 * 24-character unbroken run is not a name anybody writes. Note this is
 * a RUN bound, not a length bound: `acme_internal_billing_service.apikey`
 * is 36 characters and passes, which is the false positive a naive
 * length bound would produce. */
const RUN_BOUND = 24
const UNBROKEN_RUN = new RegExp('[A-Za-z0-9]{' + RUN_BOUND + ',}')

/** Normalize, then validate (§4.2). Raises `station_config_invalid`
 * with EVERY struct error at once - an eighteen-instance config that
 * touches three of them must not die because the eighteenth has a
 * typo'd package name - then the §5.2 scans.
 *
 * Takes the NORMALIZED form. Handing it a raw config is the mistake
 * §4.2 exists to prevent, so callers go through open()/loadConfig. */
export function validateConfig(normalized: any): any {
  const errs: string[] = []
  validate(normalized, configShape(), { errs })
  if (0 < errs.length) {
    throw new StationError('station_config_invalid',
      errs.join('; ') + renamehint(normalized))
  }

  scanConfig(normalized)
  return normalized
}

/** `plugin` is REMOVED, not aliased (§3.4) - a deprecated alias would
 * be a second grammar for one concept in 17 ports. The shape already
 * rejects it as an unexpected key; this says what to rename, because
 * "unexpected key: plugin" alone does not, and the migration for a
 * single-instance project is exactly this one rename. */
function renamehint(cfg: any): string {
  const profiles = ismap(cfg) && ismap(cfg.profiles) ? cfg.profiles : {}
  const hit = Object.keys(profiles)
    .filter((p) => ismap(profiles[p]) && undefined !== profiles[p].plugin)
  if (0 === hit.length) { return '' }
  return '; rename `plugin` to `sdk` in ' +
    hit.map((p) => 'profiles.' + p).join(', ') +
    ' - the keys are unchanged, an untagged ref IS an api slug (§3.4)'
}

/** The §5.2 scans, over the parts of the grammar that hold arbitrary
 * data. Everything else is closed by construction and needs no scan. */
function scanConfig(cfg: any): void {
  const secrets: string[] = []
  const reserved: string[] = []
  const invalid: string[] = []

  const profiles = ismap(cfg) && ismap(cfg.profiles) ? cfg.profiles : {}
  for (const pname of Object.keys(profiles)) {
    const prof = profiles[pname]
    if (!ismap(prof)) { continue }
    const ppath = 'profiles.' + pname

    checkfeatures(prof.feature, ppath + '.feature', secrets, reserved, invalid)

    for (const bkey of ['api', 'sdk']) {
      if (!ismap(prof[bkey])) { continue }
      for (const ref of Object.keys(prof[bkey])) {
        const block = prof[bkey][ref]
        if (!ismap(block)) { continue }
        const bpath = ppath + '.' + bkey + '.' + ref

        // The block's own `secret` holds a NAME. resolveProfile checks
        // it again per instance (station_secret_name); this catches it
        // at open(), for the whole file at once.
        if (undefined !== block.secret) {
          secretvalue(block.secret, bpath + '.secret', secrets)
        }

        // `options` is passthrough to a generated constructor, so it is
        // the one place a value can hide.
        scan(block.options, bpath + '.options', secrets, reserved)
        checkfeatures(block.feature, bpath + '.feature', secrets, reserved, invalid)

        // §4.4: `$CHILD` in list mode does not validate element 0, so
        // `hosts: [1]` passes the shape as written. Three lines, applied
        // where the shape cannot reach, raising the same code the shape
        // would - and pinned in the corpus so the workaround is removed
        // deliberately when struct is fixed rather than forgotten.
        const hosts = ismap(block.policy) ? block.policy.hosts : undefined
        firstelement(hosts, bpath + '.policy.hosts', invalid)
      }
    }
  }

  if (0 < invalid.length) {
    throw new StationError('station_config_invalid', invalid.join('; '))
  }
  if (0 < reserved.length) {
    throw new StationError('station_feature_reserved', reserved.join('; '))
  }
  if (0 < secrets.length) {
    throw new StationError('station_config_secret', secrets.join('; '))
  }
}

/** A feature map at any level. `station` is reserved: station composes
 * its own wrap and a config that reconfigures it is asking for a state
 * the ordering rules cannot express (§8.4). */
function checkfeatures(
  f: any, path: string, secrets: string[], reserved: string[],
  invalid: string[]
): void {
  if (!ismap(f)) { return }
  for (const name of Object.keys(f)) {
    const fpath = path + '.' + name
    if ('station' === name) {
      reserved.push(path + '.station is reserved: station composes its own ' +
        'wrap and it cannot be configured from station.json')
    }
    const order = ismap(f[name]) ? f[name].order : undefined
    if (ismap(order)) {
      firstelement(order.before, fpath + '.order.before', invalid)
      firstelement(order.after, fpath + '.order.after', invalid)
    }
    scan(f[name], fpath, secrets, reserved)
  }
}

/** §4.4: `$CHILD` in list mode DOES NOT VALIDATE ELEMENT 0. Verified:
 * `["a", 1]` fails at index 1, `[1]` passes. validate_CHILD installs the
 * template across the data's indices, sets keyI = 0 and returns element
 * 0 as the slot value, and the injection loop resumes past it. An
 * upstream struct defect; filing it is a deliverable of this plan.
 *
 * It reaches EVERY string list in the shape. §4.4 says the only one left
 * is `policy.hosts` because the profile-level `order` list is gone - but
 * §8.4's per-feature `order` carries `before`/`after` string lists, so
 * the reach is three lists, not one, and §4.5 pins `order: [7]`
 * accordingly. Applied where the shape cannot reach, raising the same
 * code the shape would, and pinned in the corpus so the workaround is
 * removed deliberately when struct is fixed rather than forgotten. */
function firstelement(list: any, path: string, invalid: string[]): void {
  if (!Array.isArray(list) || 0 === list.length) { return }
  if ('string' === typeof list[0]) { return }
  invalid.push('Expected field ' + path + '.0 to be string, but found ' +
    kindof(list[0]) + ': ' + JSON.stringify(list[0]))
}

/** Recursive over EVERY nested map and list, not just the top level -
 * a credential one level down is the case a top-level scan misses. */
function scan(
  node: any, path: string, secrets: string[], reserved: string[]
): void {
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) {
      scan(node[i], path + '.' + i, secrets, reserved)
    }
    return
  }
  if ('string' === typeof node) { userinfo(node, path, secrets); return }
  if (!ismap(node)) { return }

  for (const key of Object.keys(node)) {
    const kpath = path + '.' + key
    const val = node[key]

    // §8.6: station owns feature composition, so an `options.feature`
    // in a declarative config is a second, unreconciled ordering input.
    if ('feature' === key) {
      reserved.push(kpath + ' is reserved: configure features under the ' +
        'block\'s own `feature` key, not through `options`')
      continue
    }

    if ('secret' === key.toLowerCase()) {
      secretvalue(val, kpath, secrets)
      continue
    }

    if (credentialkey(key)) {
      secrets.push(kpath + ' is a credential-shaped key: station.json ' +
        'holds secret NAMES, never values (§5.2)')
      continue
    }

    scan(val, kpath, secrets, reserved)
  }
}

function credentialkey(key: string): boolean {
  const low = String(key).toLowerCase().replace(/[^a-z0-9]+/g, '')
  if (CREDENTIAL_KEYS.includes(low)) { return true }
  const tok = envtoken(key)
  return CREDENTIAL_SUFFIX.some((s) => tok.endsWith(s))
}

/** A `secret`-named key holds a NAME, and that exemption is not a
 * loophole - it is the whole design. Two checks, not one, and they live
 * in the same three lines precisely so a port cannot implement only the
 * first and inherit the gap the second exists to close. */
function secretvalue(val: any, path: string, secrets: string[]): void {
  if ('string' !== typeof val) {
    secrets.push(path + ' must be a secret name (a string), but found ' +
      kindof(val))
    return
  }
  if (!validname(val)) {
    secrets.push(path + ' is not a valid sekreto name, so it cannot be a ' +
      'name and must not be a value: ' + JSON.stringify(val))
    return
  }
  if (UNBROKEN_RUN.test(val)) {
    secrets.push(path + ' contains an unbroken alphanumeric run of ' +
      RUN_BOUND + ' or more characters, which is not a name anybody writes')
  }
}

/** One rule about values rather than keys, because the `proxy` feature
 * makes it concrete: `http://user:pass@proxy.internal:8080`. */
function userinfo(val: string, path: string, secrets: string[]): void {
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(val)) { return }
  let u: URL
  try { u = new URL(val) } catch (e) { return }
  if ('' !== u.username || '' !== u.password) {
    secrets.push(path + ' is a URL carrying userinfo, which puts a ' +
      'credential in the config file; use the proxy feature\'s ' +
      '`fromEnv` option instead (§8.6)')
  }
}

function kindof(v: any): string {
  if (null === v) { return 'null' }
  if (Array.isArray(v)) { return 'list' }
  if ('number' === typeof v) {
    return Number.isInteger(v) ? 'integer' : 'decimal'
  }
  return typeof v
}

function ismap(v: any): boolean {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}
