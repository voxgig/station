# station.json loading, profile selection, and profile resolution
# (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical.

import json
import os

from voxgig_sekreto import validname

from .error import StationError


def find_config_file(from_dir=None):
    """station.json lookup: cwd upward to the repo root, then
    ~/.voxgig/station.json (design station.md 3.5). A repo root is where
    .git lives; with no repo the walk stops at the filesystem root."""
    directory = os.path.abspath(from_dir or os.getcwd())
    while True:
        candidate = os.path.join(directory, 'station.json')
        if os.path.exists(candidate):
            return candidate
        at_repo_root = os.path.exists(os.path.join(directory, '.git'))
        parent = os.path.dirname(directory)
        if at_repo_root or parent == directory:
            break
        directory = parent
    home = os.path.join(os.path.expanduser('~'), '.voxgig', 'station.json')
    return home if os.path.exists(home) else None


def load_config(from_dir=None):
    file = find_config_file(from_dir)
    if file is None:
        return None
    with open(file, encoding='utf-8') as handle:
        return json.load(handle)


def select_profile(opt_profile=None):
    """Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
    else 'default' (design station.md 3.5 - env vars rank above
    station.json but below open() opts; profile NAME selection follows
    the same order with open() opts winning)."""
    if opt_profile is not None and '' != opt_profile:
        return opt_profile
    env = os.environ.get('VOXGIG_STATION_PROFILE')
    if env is not None and '' != env:
        return env
    return 'default'


def resolve_profile(config, profile_name):
    """Merge the base profile ('default') with the selected overlay:
    deep-merge per plugin, EXCEPT secrets.providers which replaces
    wholesale (design station.md 3.5, 5.2 - chain order decides which
    store wins, so a positional merge would be actively dangerous). The
    `profile` corpus section pins this. Returns a plain dict
    {name, providers, plugin}."""
    config = config if isinstance(config, dict) else {}
    profiles = config.get('profiles') or {}
    base = profiles.get('default') or {}
    overlay = {} if 'default' == profile_name else (profiles.get(profile_name) or {})

    providers = _providers_of(overlay)
    if providers is None:
        providers = _providers_of(base)
    if providers is None:
        providers = [{'kind': 'env'}]

    plugin = {}
    for src in (base.get('plugin') or {}, overlay.get('plugin') or {}):
        for slug in src.keys():
            merged = dict(plugin.get(slug) or {})
            merged.update(src[slug] or {})
            plugin[slug] = merged

    # A configured secret name sekreto would reject is caught at profile
    # load, not first request (design station.md 14 station_secret_name).
    for slug in plugin.keys():
        name = plugin[slug].get('secret')
        if name is not None and not validname(name):
            raise StationError(
                'station_secret_name',
                'profile "' + profile_name + '" plugin "' + slug +
                '": secret name rejected by sekreto: ' + json.dumps(name))

    return {'name': profile_name, 'providers': providers, 'plugin': plugin}


def _providers_of(profile):
    secrets = profile.get('secrets')
    if not isinstance(secrets, dict):
        return None
    return secrets.get('providers')
