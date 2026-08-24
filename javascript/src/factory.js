// The factory table (design §6.2).
//
// A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
// function, and leaving the second half out was a hole in the first
// draft of §6.2.
//
// Station composes the ordered feature array FOR the constructor, so it
// needs the transport roles and the feature option schemas BEFORE
// construction - but §7.5 has the adapter build and register its
// descriptor DURING construction. Nothing would be known in time.
//
// The config is available, though: `configDefinition` emits it as a
// module-level constant in the generated package, so it exists as soon
// as the package is linked and long before any instance is built.
// Station normalizes the descriptor AT PROVIDE TIME, and three things
// follow:
//
//  - §7.4's per-api descriptor cache is populated at registration
//    rather than on first construction;
//  - `check()` can validate every instance's feature config WITHOUT
//    constructing anything;
//  - the adapter's registration during construction becomes a
//    reconciliation - same descriptor, now bound to a live client -
//    rather than the first sighting.
//
// The table is PROCESS-GLOBAL because path 1 of §6.2 is module
// self-registration: a generated package registers itself when it is
// linked, which happens once per process and not once per Station.
//
// A port of typescript/src/factory.ts, which is canonical.

const { StationError } = require('./error')
const { normalizeDescriptor } = require('./descriptor')

const TABLE = new Map()

// Register an api's `{construct, config}` pair.
//
// Idempotent per api: registering the SAME pair twice is a no-op,
// because module self-registration and an explicit `provide` for one
// api is an ordinary thing for an application to end up with. A second
// registration with a DIFFERENT factory is `station_factory_conflict` -
// silently picking one of two SDK builds is not a thing to do quietly.
function provide(api, factory) {
  const slug = String(api)
  const prior = TABLE.get(slug)
  if (null != prior) {
    if (prior.construct === factory.construct && prior.config === factory.config) {
      return prior
    }
    throw new StationError('station_factory_conflict',
      'two different factories registered for api "' + slug + '"; a ' +
      'process has one build of an SDK, and picking between two ' +
      'silently is not a thing to do quietly')
  }

  // AT PROVIDE TIME, which is the whole point of carrying `config`.
  const { descriptor, warnings } = normalizeDescriptor(factory.config, undefined)
  const entry = {
    api: slug,
    construct: factory.construct,
    config: factory.config,
    descriptor,
    warnings,
  }
  TABLE.set(slug, entry)
  return entry
}

function factoryFor(api) {
  return TABLE.get(String(api))
}

function provided() {
  return Array.from(TABLE.keys()).sort()
}

// Test seam. The table is process-global by design, so a suite that
// registers factories has to be able to put the process back.
function resetFactories() {
  TABLE.clear()
}

module.exports = {
  factoryFor,
  provide,
  provided,
  resetFactories,
}
