
import { StationError } from './error'
import { Factory, factoryFor, provide } from './factory'

export const DEFAULT_EXPORT = 'SDK'

export function camelify(slug: string): string {
  return String(slug).split(/[^A-Za-z0-9]+/).filter((s) => '' !== s)
    .map((s) => s[0].toUpperCase() + s.slice(1))
    .join('')
}

/** Only MODULE NAMES, resolved by the host language's ordinary
 * resolution from the application root. Never a filesystem path, never
 * a URL, never anything relative — a config file naming a path is a
 * config file reaching outside the dependency graph it is allowed to
 * name. */
export function checkPackage(api: string, pkg: string): string {
  const p = String(pkg)
  const seg = p.split('/').some((x) => '.' === x || '..' === x)
  const bad =
    '' === p ||
    p.startsWith('.') ||
    p.startsWith('/') ||
    p.startsWith('~') ||
    seg ||
    -1 !== p.indexOf('://') ||
    -1 !== p.indexOf('\\')
  if (bad) {
    throw new StationError('station_sdk_load',
      'api "' + api + '": `package` must be a module name resolved from ' +
      'the application root, not a path or URL: ' + JSON.stringify(pkg))
  }
  return p
}

export function factoryFromModule(
  api: string, mod: any, exportName?: string
): Factory {
  const tried: string[] = []
  const pick = (n: string): any => {
    tried.push(n)
    return null == mod ? undefined : mod[n]
  }

  let ctor = null == exportName || '' === exportName
    ? undefined : pick(exportName)
  if (null == ctor) { ctor = pick(DEFAULT_EXPORT) }
  if (null == ctor) { ctor = pick(camelify(api) + 'SDK') }

  if ('function' !== typeof ctor) {
    throw new StationError('station_sdk_load',
      'api "' + api + '": no SDK constructor found on the module; tried [' +
      tried.join(', ') + ']. Set `export` to the exported name.')
  }

  const config = mod.config ?? mod.CONFIG
  if (null == config) {
    throw new StationError('station_sdk_load',
      'api "' + api + '": the module exports a constructor but no `config` ' +
      'singleton, so its feature schema and transport roles cannot be read ' +
      'before construction (§6.2)')
  }

  const construct = (options: any) => new (ctor as any)(options)
  return { construct, config }
}

/** Synchronous load, for CommonJS. Returns true when the api has a
 * factory afterwards — either because importing the package triggered
 * self-registration, or because one was built from its exports. */
export function loadSync(api: string, pkg: string, exportName?: string): boolean {
  checkPackage(api, pkg)
  if (null != factoryFor(api)) { return true }

  let mod: any
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    mod = require(pkg)
  }
  catch (e: any) {
    const code = String(e?.code || '')
    if ('ERR_REQUIRE_ESM' === code) {
      throw new StationError('station_sdk_load',
        'api "' + api + '": package "' + pkg + '" is ESM-only and cannot be ' +
        'loaded synchronously; `await station.load()` at startup, then ' +
        'sdk() is synchronous again for everything (§6.3)')
    }
    throw new StationError('station_sdk_load',
      'api "' + api + '": package "' + pkg + '" could not be imported: ' +
      String(e?.message || e))
  }

  if (null != factoryFor(api)) { return true }

  provide(api, factoryFromModule(api, mod, exportName))
  return true
}

export const nativeImport: (p: string) => Promise<any> =
  new Function('p', 'return import(p)') as any

export async function loadAsync(
  api: string, pkg: string, exportName?: string
): Promise<boolean> {
  checkPackage(api, pkg)
  if (null != factoryFor(api)) { return true }

  let mod: any
  try { mod = await nativeImport(pkg) }
  catch (e: any) {
    throw new StationError('station_sdk_load',
      'api "' + api + '": package "' + pkg + '" could not be imported: ' +
      String(e?.message || e))
  }

  if (null != factoryFor(api)) { return true }

  const flat = null != mod?.default && null == mod?.config ? mod.default : mod
  provide(api, factoryFromModule(api, flat, exportName))
  return true
}
