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
# module-level constant, so it exists as soon as the package is imported
# and long before any instance is built. Station normalizes the
# descriptor AT PROVIDE TIME, and three things follow:
#
#  - the per-api descriptor cache is populated at registration rather
#    than on first construction;
#  - `check()` can validate every instance's feature config WITHOUT
#    constructing anything;
#  - the adapter's registration during construction becomes a
#    reconciliation - same descriptor, now bound to a live client -
#    rather than the first sighting.
#
# The table is PROCESS-GLOBAL because path 1 of 6.2 is module
# self-registration: a generated package registers itself when it is
# imported, which happens once per process and not once per Station.
#
# A port of typescript/src/factory.ts, which is canonical. Guarded by
# one lock, like the rest of this port's process-wide state.

import threading

from .descriptor import normalize_descriptor
from .error import StationError

_TABLE = {}
_LOCK = threading.Lock()


def provide(api, factory):
    """Register an api's `{construct, config}` pair.

    Idempotent per api: registering the SAME pair twice is a no-op,
    because module self-registration and an explicit `provide` for one
    api is an ordinary thing for an application to end up with. A second
    registration with a DIFFERENT factory is station_factory_conflict -
    silently picking one of two SDK builds is not a thing to do quietly."""
    slug = str(api)
    factory = factory or {}
    construct = factory.get('construct')
    config = factory.get('config')

    with _LOCK:
        prior = _TABLE.get(slug)
        if prior is not None:
            if prior['construct'] is construct and prior['config'] is config:
                return prior
            raise StationError(
                'station_factory_conflict',
                'two different factories registered for api "' + slug +
                '"; a process has one build of an SDK, and picking between '
                'two silently is not a thing to do quietly')

        # AT PROVIDE TIME, which is the whole point of carrying `config`.
        descriptor, warnings = normalize_descriptor(config, None)
        entry = {
            'api': slug,
            'construct': construct,
            'config': config,
            'descriptor': descriptor,
            'warnings': warnings,
        }
        _TABLE[slug] = entry
        return entry


def factory_for(api):
    with _LOCK:
        return _TABLE.get(str(api))


def provided():
    with _LOCK:
        return sorted(_TABLE.keys())


def reset_factories():
    """Test seam. The table is process-global by design, so a suite that
    registers factories has to be able to put the process back."""
    with _LOCK:
        _TABLE.clear()
