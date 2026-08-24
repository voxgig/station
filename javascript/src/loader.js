// The loader (design §6.3), where the language allows it.
//
// In ts, js, py, rb, php, perl, lua, elixir and clojure a module can be
// imported by name at runtime, so `api.<slug>.package` closes the loop:
// station imports the package (which triggers self-registration, §6.2
// path 1) and then looks up the factory.
//
// `sdk()` IS SYNCHRONOUS, AND IN TS/JS THAT BOUNDS WHAT THE LOADER CAN
// IMPORT. A CommonJS package loads synchronously through `require`; an
// ESM-only package only loads through `import()`, which is a promise.
// Making `sdk()` async to cover that would put an `await` in front of
// every call site in every language for a cost only two of them pay.
// So the rule is explicit rather than discovered at runtime:
//
//  - the synchronous loader handles CommonJS, which is every SDK sdkgen
//    generates (the js target is `"type": "commonjs"`);
//  - ESM packages load through an explicit `await station.load()`
//    preload, after which `sdk()` is synchronous again for everything -
//    one `await` at startup rather than one per call site;
//  - a package only `import()` can load, reached through `sdk()`
//    without a preload, is `station_sdk_load` WITH THE REMEDY IN THE
//    MESSAGE. Never a silent half-loaded client.
//
// THIS IS A CODE-LOADING SURFACE DRIVEN BY A CONFIG FILE, so it has
// rules, and they are enforced here rather than documented and hoped
// for. See `checkPackage` and the `repoScoped` argument.
//
// A port of typescript/src/loader.ts, which is canonical.

const { StationError } = require('./error')
const { factoryFor, provide } = require('./factory')

// The fixed alias every generated package exports.
//
// `export` defaults to this rather than to a derived class name because
// it is the same identifier in every generated package, where
// `camelify(slug) + 'SDK'` is a rule that has to be recomputed and can
// be wrong. The derived name is the SECOND attempt and an explicit
// `export` the third.
const DEFAULT_EXPORT = 'SDK'

// `stripe-eu` -> `StripeEu`, for the second-attempt export name.
function camelify(slug) {
  return String(slug).split(/[^A-Za-z0-9]+/).filter((s) => '' !== s)
    .map((s) => s[0].toUpperCase() + s.slice(1))
    .join('')
}

// Only MODULE NAMES, resolved by the host language's ordinary
// resolution from the application root. Never a filesystem path, never
// a URL, never anything relative - a config file naming a path is a
// config file reaching outside the dependency graph it is allowed to
// name.
function checkPackage(api, pkg) {
  const p = String(pkg)
  // A TRAVERSAL SEGMENT IS NOT A LEADING MARKER, and checking only the
  // first character missed it: `pkg/../../escape` starts with neither
  // `.` nor `/`, so it passed - and node resolves it through
  // `node_modules/pkg/../../escape`, importing application-local code
  // from outside the named dependency. The whole point of this function
  // is that a configured package stays inside the dependency graph a
  // reviewer can see.
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

// Build a `{construct, config}` pair from a module that self-registered
// nothing - the retrofit path for a package whose SDK predates the
// station feature. It is not descriptor-blind: a generated main module
// exports its constructor AND the `config` singleton beside it.
function factoryFromModule(api, mod, exportName) {
  const tried = []
  const pick = (n) => {
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

  const construct = (options) => new ctor(options)
  return { construct, config }
}

// Synchronous load, for CommonJS. Returns true when the api has a
// factory afterwards - either because importing the package triggered
// self-registration, or because one was built from its exports.
function loadSync(api, pkg, exportName) {
  checkPackage(api, pkg)
  if (null != factoryFor(api)) { return true }

  let mod
  try {
    mod = require(pkg)
  }
  catch (e) {
    // ERR_REQUIRE_ESM is the case the preload exists for, and the
    // message has to name the remedy rather than the symptom.
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

  // Path 1: the module self-registered while being imported.
  if (null != factoryFor(api)) { return true }

  provide(api, factoryFromModule(api, mod, exportName))
  return true
}

// The ESM preload behind `await station.load()`. Imports the package
// and fills the SAME table the synchronous path fills.
//
// A plain CommonJS source file may call dynamic `import()` natively, so
// this port needs none of loader.ts's `new Function` seam - that exists
// only because the TypeScript compiler rewrites a literal `import()` in
// a commonjs emit.
async function loadAsync(api, pkg, exportName) {
  checkPackage(api, pkg)
  if (null != factoryFor(api)) { return true }

  let mod
  try { mod = await import(pkg) }
  catch (e) {
    throw new StationError('station_sdk_load',
      'api "' + api + '": package "' + pkg + '" could not be imported: ' +
      String(e?.message || e))
  }

  if (null != factoryFor(api)) { return true }

  // An ESM namespace puts a CommonJS module's exports under `default`.
  const flat = null != mod?.default && null == mod?.config ? mod.default : mod
  provide(api, factoryFromModule(api, flat, exportName))
  return true
}

module.exports = {
  DEFAULT_EXPORT,
  camelify,
  checkPackage,
  factoryFromModule,
  loadAsync,
  loadSync,
}
