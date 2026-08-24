# frozen_string_literal: true

# The factory table (design station.md 6.2).
#
# A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
# callable, and leaving the second half out is a hole.
#
# Station composes the ordered feature array FOR the constructor, so it
# needs the transport roles and the feature option schemas BEFORE
# construction - but the adapter builds and registers its descriptor
# DURING construction. Nothing would be known in time.
#
# The config is available, though: the generated package emits it as a
# module-level constant, so it exists as soon as the package is required
# and long before any instance is built. Station normalizes the
# descriptor AT PROVIDE TIME, and three things follow:
#
#  - the per-api descriptor cache is populated at registration rather
#    than on first construction;
#  - check() can validate every instance's feature config WITHOUT
#    constructing anything;
#  - the adapter's registration during construction becomes a
#    RECONCILIATION - same descriptor, now bound to a live client -
#    rather than the first sighting.
#
# The table is PROCESS-GLOBAL because path 1 of 6.2 is module
# self-registration: a generated package registers itself when it is
# required, which happens once per process and not once per Station.
#
# A port of typescript/src/factory.ts, which is canonical. Guarded by one
# mutex, like the rest of this port's process-wide state.

require_relative 'descriptor'
require_relative 'error'

module VoxgigStation
  FACTORY_MUTEX = Mutex.new
  @factories = {}

  module_function

  # Register an api's `{construct, config}` pair.
  #
  # Idempotent per api: registering the SAME pair twice is a no-op,
  # because module self-registration plus an explicit `provide` for one
  # api is an ordinary thing for an application to end up with. A second
  # registration with a DIFFERENT factory is station_factory_conflict -
  # silently picking one of two SDK builds is not a thing to do quietly.
  def provide(api, factory)
    slug = api.to_s
    construct = factory_part(factory, 'construct')
    config = factory_part(factory, 'config')

    FACTORY_MUTEX.synchronize do
      prior = @factories[slug]
      unless prior.nil?
        if prior[:construct].equal?(construct) && prior[:config].equal?(config)
          return prior
        end

        raise StationError.new('station_factory_conflict',
          'two different factories registered for api "' + slug + '"; a ' \
          'process has one build of an SDK, and picking between two ' \
          'silently is not a thing to do quietly')
      end

      # AT PROVIDE TIME, which is the whole point of carrying `config`.
      normalized = normalize_descriptor(config, nil)
      entry = {
        api: slug,
        construct: construct,
        config: config,
        descriptor: normalized[:descriptor],
        warnings: normalized[:warnings],
      }
      @factories[slug] = entry
      entry
    end
  end

  def factory_for(api)
    FACTORY_MUTEX.synchronize { @factories[api.to_s] }
  end

  def provided
    FACTORY_MUTEX.synchronize { @factories.keys.sort }
  end

  # Test seam. The table is process-global by design, so a suite that
  # registers factories has to be able to put the process back.
  def reset_factories
    FACTORY_MUTEX.synchronize { @factories.clear }
    nil
  end

  # Construction options are string- or symbol-keyed throughout this port
  # (the generated SDKs' convention is strings; Ruby callers reach for
  # symbols), so the factory pair is read the same way.
  def factory_part(factory, key)
    return nil unless factory.is_a?(Hash)

    factory.key?(key) ? factory[key] : factory[key.to_sym]
  end
end
