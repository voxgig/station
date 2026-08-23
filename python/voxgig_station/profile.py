# station.json loading, profile selection, and profile resolution
# (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical.

import json
import os

from voxgig_sekreto import validname

from .descriptor import secretname_default
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


BLOCK_DEFAULTS = {
    'active': lambda: True,
    'feature': lambda: {},
}

# The one block key carrying the timing rule: applied AFTER the merge,
# never before (design 3.3, 4.2).
MERGE_SENSITIVE = ['active']


def refapi(ref):
    """The api half of a ref is the substring before the first `$`, and
    an untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
    point: under the old free-form identity which api an instance used
    was itself a merged value, so a port that got the phasing wrong
    silently picked another api's defaults."""
    ref = str(ref)
    at = ref.find('$')
    return ref if -1 == at else ref[:at]


def _shallow(*sources):
    """Shallow merge, per key, left to right - each source over the one
    before it. An overlay's `policy` REPLACES the base's entirely rather
    than merging `hosts` into it; an allowlist that widens because two
    precedence levels merged is the failure this rule prevents."""
    out = {}
    for src in sources:
        if isinstance(src, dict):
            out.update(src)
    return out


def _sortedkeys(*maps):
    keys = set()
    for m in maps:
        if isinstance(m, dict):
            keys.update(m.keys())
    return sorted(keys)


def resolve_profile(config, profile_name):
    """Merge the base profile ('default') with the selected overlay.

    Design 3.3's total order for the two block levels, lowest first:

      base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]

    PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
    LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
    namespace, then put instance over api" - that lets every instance
    value beat every api value, so a production `api.stripe.policy` would
    fail to override a default profile's `sdk.stripe$test.policy`,
    silently keeping the wider allowlist in production.

    `secrets.providers` replaces wholesale, never merges (3.5, 5.2).
    Returns a plain dict {name, providers, api, sdk}."""
    config = config if isinstance(config, dict) else {}
    profiles = config.get('profiles') or {}
    base = profiles.get('default') or {}
    overlay = {} if 'default' == profile_name else (profiles.get(profile_name) or {})

    providers = _providers_of(overlay)
    if providers is None:
        providers = _providers_of(base)
    if providers is None:
        providers = [{'kind': 'env'}]

    base_api = base.get('api') or {}
    over_api = overlay.get('api') or {}
    base_sdk = base.get('sdk') or {}
    over_sdk = overlay.get('sdk') or {}

    # The api-level defaults in effect for this profile. A REPORT, not an
    # input to the instance merge below.
    api = {}
    for slug in _sortedkeys(base_api, over_api):
        api[slug] = _shallow(base_api.get(slug), over_api.get(slug))

    # An api block declares no instance of its own (3.1), so the ref set
    # comes from the two `sdk` maps alone.
    sdk = {}
    for ref in _sortedkeys(base_sdk, over_sdk):
        a = refapi(ref)
        merged = _shallow(base_api.get(a), base_sdk.get(ref),
                          over_api.get(a), over_sdk.get(ref))

        # Defaults are applied ONCE, to the fully merged instance. Had
        # the overlay block carried a synthesized `active: True` into the
        # merge, a one-key environment override would silently re-enable
        # an integration the base declared inactive.
        for k, mk in BLOCK_DEFAULTS.items():
            if k not in merged:
                merged[k] = mk()

        sdk[ref] = merged

    _checksecrets(sdk, profile_name)

    return {'name': profile_name, 'providers': providers,
            'api': api, 'sdk': sdk}


def _checksecrets(sdk, profile_name):
    """A configured secret name sekreto would reject is caught at profile
    load, not first request (14 station_secret_name) - and then the
    DERIVED names are checked for uniqueness, because envtoken is lossy:
    it collapses any run of non-alphanumerics to `_`, so `stripe$test`
    and an untagged instance of a `stripe-test` api both derive
    `stripe_test.apikey` and would silently share one credential.

    Two instances that EXPLICITLY name one secret are not a collision -
    that is the shared-key case the api-level `secret` exists for."""
    refs = sorted(sdk.keys())

    for ref in refs:
        name = sdk[ref].get('secret')
        if name is not None and not validname(name):
            raise StationError(
                'station_secret_name',
                'profile "' + profile_name + '" sdk "' + ref +
                '": secret name rejected by sekreto: ' + json.dumps(name))

    seen = {}
    for ref in refs:
        written = sdk[ref].get('secret')
        derived = written is None or '' == written
        name = secretname_default(ref) if derived else written

        prior = seen.get(name)
        if prior is not None and (derived or prior[1]):
            raise StationError(
                'station_secret_collision',
                'profile "' + profile_name + '": instances "' + prior[0] +
                '" and "' + ref + '" both resolve to secret name "' + name +
                '", so they would share one credential; name it explicitly '
                'on each, or at the api level to share it deliberately (5.1)')
        if prior is None:
            seen[name] = (ref, derived)


def _providers_of(profile):
    secrets = profile.get('secrets')
    if not isinstance(secrets, dict):
        return None
    return secrets.get('providers')
