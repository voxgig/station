
import Fs from 'node:fs'
import Os from 'node:os'
import Path from 'node:path'

import { validname } from '@voxgig/sekreto'

import { secretnameDefault } from './descriptor'
import { StationError } from './error'
import { BLOCK_DEFAULTS } from './shape'
import { StationConfig, SdkBlock } from './types'

export function selectProfile(optProfile?: string): string {
  if (null != optProfile && '' !== optProfile) { return optProfile }
  const env = process.env.VOXGIG_STATION_PROFILE
  if (null != env && '' !== env) { return env }
  return 'default'
}

export function refapi(ref: string): string {
  const at = String(ref).indexOf('$')
  return -1 === at ? String(ref) : String(ref).slice(0, at)
}

export type ResolvedProfile = {
  name: string
  providers: any[]
  api: Record<string, SdkBlock>
  // Instances, keyed by ref. An `api` block declares no instance of its
  // own (§3.1), so it never creates an entry here.
  sdk: Record<string, SdkBlock>
}

function shallow(...sources: any[]): any {
  const out: any = {}
  for (const src of sources) {
    if (null == src || 'object' !== typeof src || Array.isArray(src)) { continue }
    for (const k of Object.keys(src)) { out[k] = src[k] }
  }
  return out
}

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

    for (const k of Object.keys(BLOCK_DEFAULTS)) {
      if (undefined === merged[k]) { merged[k] = BLOCK_DEFAULTS[k]() }
    }

    sdk[ref] = merged
  }

  checksecrets(sdk, profileName)

  return { name: profileName, providers, api, sdk }
}

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
  // A file that is not JSON is a config error, not a raw SyntaxError
  // escaping open(): the reader found station.json and could not use
  // it, which is exactly what station_config_invalid exists to say.
  try {
    return JSON.parse(text)
  }
  catch (err: any) {
    throw new StationError('station_config_invalid',
      'station.json at ' + file + ' is not valid JSON: ' + err.message)
  }
}

export function configScope(from?: string): 'repo' | 'user' | 'none' {
  const file = findConfigFile(from)
  if (null == file) { return 'none' }
  const home = Path.join(Os.homedir(), '.voxgig', 'station.json')
  return file === home ? 'user' : 'repo'
}
