
import { clone, validate } from '@voxgig/struct'
import { validname } from '@voxgig/sekreto'

import { CONFIG_SHAPE } from './config-shape'
import { StationError } from './error'
import { envtoken } from './descriptor'


/** Profile-level containers. Safe to materialize early either way:
 * they are containers, and a missing one merges as empty regardless. */
export const PROFILE_DEFAULTS: { [k: string]: () => any } = {
  secrets: () => ({ providers: [{ kind: 'env' }] }),
  api: () => ({}),
  sdk: () => ({}),
  feature: () => ({}),
}

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

const CREDENTIAL_SUFFIX = ['_KEY', '_TOKEN', '_SECRET', '_PASSWORD']

const RUN_BOUND = 24
const UNBROKEN_RUN = new RegExp('[A-Za-z0-9]{' + RUN_BOUND + ',}')

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

function renamehint(cfg: any): string {
  const profiles = ismap(cfg) && ismap(cfg.profiles) ? cfg.profiles : {}
  const hit = Object.keys(profiles)
    .filter((p) => ismap(profiles[p]) && undefined !== profiles[p].plugin)
  if (0 === hit.length) { return '' }
  return '; rename `plugin` to `sdk` in ' +
    hit.map((p) => 'profiles.' + p).join(', ') +
    ' - the keys are unchanged, an untagged ref IS an api slug (§3.4)'
}

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

        scan(block.options, bpath + '.options', secrets, reserved)
        checkfeatures(block.feature, bpath + '.feature', secrets, reserved, invalid)

        checkpolicy(block.policy, bpath + '.policy', invalid)
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

const BUDGET_KEYS = ['concurrency', 'rps']

function checkpolicy(policy: any, path: string, invalid: string[]): void {
  if (!ismap(policy)) { return }

  firstelement(policy.hosts, path + '.hosts', invalid)

  const allow = policy.allow
  if (ismap(allow)) {
    firstelement(allow.op, path + '.allow.op', invalid)
    firstelement(allow.method, path + '.allow.method', invalid)
  }

  const budget = policy.budget
  if (ismap(budget)) {
    const unknown = Object.keys(budget)
      .filter((k) => !BUDGET_KEYS.includes(k)).sort()
    if (0 < unknown.length) {
      invalid.push('Unexpected keys at field ' + path + '.budget: ' +
        unknown.join(', '))
    }
  }
}

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
