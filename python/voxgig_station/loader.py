# The loader (design station.md 6.3), where the language allows it.
#
# In ts, js, py, rb, php, perl, lua, elixir and clojure a module can be
# imported by name at runtime, so `api.<slug>.package` closes the loop:
# station imports the package (which triggers self-registration, 6.2
# path 1) and then looks up the factory.
#
# py-specific: THERE IS ONE MODULE SYSTEM, so there is one loader.
# `sdk()` is synchronous and `importlib.import_module` is synchronous,
# so the ts/js CommonJS-vs-ESM split - `loadAsync` and the
# `await station.load()` preload it exists for - has no counterpart
# here. `Station.load()` is kept as a synchronous preload of the
# declared packages (see Station.load); nothing needs it before `sdk()`.
#
# THIS IS A CODE-LOADING SURFACE DRIVEN BY A CONFIG FILE, so it has
# rules, and they are enforced here rather than documented and hoped
# for. See `check_package` and Station.loader_package's repo_scoped
# argument.
#
# A port of typescript/src/loader.ts, which is canonical.

import importlib
import json
import re

from .error import StationError
from .factory import factory_for, provide

# The fixed alias every generated package exports.
#
# `export` defaults to this rather than to a derived class name because
# it is the same identifier in every generated package, where
# `camelify(slug) + 'SDK'` is a rule that has to be recomputed and can be
# wrong. The derived name is the SECOND attempt and an explicit `export`
# the third. `package` has NO default: a guessed package name that
# resolves to the wrong thing is worse than a required key.
DEFAULT_EXPORT = 'SDK'

_NONALNUM = re.compile(r'[^A-Za-z0-9]+')


def camelify(slug):
    """`stripe-eu` -> `StripeEu`, for the second-attempt export name."""
    return ''.join(s[0].upper() + s[1:]
                   for s in _NONALNUM.split(str(slug)) if '' != s)


def check_package(api, pkg):
    """Only MODULE NAMES, resolved by the host language's ordinary
    resolution from the application root. Never a filesystem path, never
    a URL, never anything relative - a config file naming a path is a
    config file reaching outside the dependency graph it is allowed to
    name."""
    p = str(pkg)
    # A TRAVERSAL SEGMENT IS NOT A LEADING MARKER, and checking only the
    # first character misses it: `pkg/../../escape` starts with neither
    # `.` nor `/`, so a first-character check passes it and the host
    # resolves it from outside the named dependency. The whole point of
    # this function is that a configured package stays inside the
    # dependency graph a reviewer can see.
    seg = any(x in ('.', '..') for x in p.split('/'))
    bad = ('' == p or
           p.startswith('.') or
           p.startswith('/') or
           p.startswith('~') or
           seg or
           -1 != p.find('://') or
           -1 != p.find('\\'))
    if bad:
        raise StationError(
            'station_sdk_load',
            'api "' + api + '": `package` must be a module name resolved '
            'from the application root, not a path or URL: ' +
            json.dumps(pkg, ensure_ascii=False, separators=(',', ':')))
    return p


def factory_from_module(api, mod, export_name=None):
    """Build a `{construct, config}` pair from a module that
    self-registered nothing - the retrofit path for a package whose SDK
    predates the station feature. It is not descriptor-blind: a generated
    main module exports its constructor AND the `config` singleton
    beside it."""
    tried = []

    def pick(n):
        tried.append(n)
        return getattr(mod, n, None)

    ctor = None
    if export_name is not None and '' != export_name:
        ctor = pick(export_name)
    if ctor is None:
        ctor = pick(DEFAULT_EXPORT)
    if ctor is None:
        ctor = pick(camelify(api) + 'SDK')

    if not callable(ctor):
        raise StationError(
            'station_sdk_load',
            'api "' + api + '": no SDK constructor found on the module; '
            'tried [' + ', '.join(tried) + ']. Set `export` to the exported '
            'name.')

    config = getattr(mod, 'config', None)
    if config is None:
        config = getattr(mod, 'CONFIG', None)
    if config is None:
        raise StationError(
            'station_sdk_load',
            'api "' + api + '": the module exports a constructor but no '
            '`config` singleton, so its feature schema and transport roles '
            'cannot be read before construction (6.2)')

    return {'construct': lambda options: ctor(options), 'config': config}


def load_sync(api, pkg, export_name=None):
    """Import the package. Returns True when the api has a factory
    afterwards - either because importing the package triggered
    self-registration, or because one was built from its exports."""
    check_package(api, pkg)
    if factory_for(api) is not None:
        return True

    try:
        mod = importlib.import_module(pkg)
    except Exception as e:
        raise StationError(
            'station_sdk_load',
            'api "' + api + '": package "' + str(pkg) +
            '" could not be imported: ' + str(e))

    # Path 1: the module self-registered while being imported.
    if factory_for(api) is not None:
        return True

    provide(api, factory_from_module(api, mod, export_name))
    return True
