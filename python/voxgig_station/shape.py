# The config grammar, as data (design station.md 4).
#
# TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
#
# struct drops the unexpected-key check for a map whose spec node ends
# up empty - "an empty spec object means the object can be open". An
# optional key is `['$ONE','$NIL', spec]`, and when the data does not
# carry that key the validator REMOVES it from the spec node. So a
# block whose keys are all optional degenerates into an open map
# exactly when the data has none of them, and `{"solar": {"bass": 1}}`
# validates clean - the one property the whole exercise is for,
# silently absent in the one case that matters.
#
# So: normalize_config materializes every documented default, and
# validate_config then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
# After normalization every container is present, so the shape can
# require them, so unexpected-key detection is live at every level and
# every error names its path.
#
# A port of typescript/src/shape.ts, which is canonical.

import json
import os
import re

from voxgig_sekreto import validname

from .descriptor import envtoken
from .error import StationError
from .structhome import structmod

_HERE = os.path.dirname(os.path.abspath(__file__))

# struct is a RUNTIME dependency (validate_config runs at open(), not
# only under test), but it is resolved on FIRST USE rather than at
# import: py imports a package as a whole, so binding it at module load
# would take `placeholder_for` down with a missing checkout.
_STRUCT = None


def _struct():
    global _STRUCT
    if _STRUCT is None:
        _STRUCT = structmod()
    return _STRUCT


# ---------------------------------------------------------------------
# The defaults table - ONE table, two callers
# ---------------------------------------------------------------------

# Profile-level containers. Safe to materialize early either way:
# they are containers, and a missing one merges as empty regardless.
PROFILE_DEFAULTS = {
    'secrets': lambda: {'providers': [{'kind': 'env'}]},
    'api': lambda: {},
    'sdk': lambda: {},
    'feature': lambda: {},
}

# Block-level. `feature` is a container and safe early.
#
# `active` IS NOT, and that is the whole timing rule: a default
# synthesized into an OVERLAY block overwrites the base's real value and
# silently reactivates an integration the base deliberately barred
# (design 3.3). So the two consumers read this same table at different
# moments - validate_config before, to every block, because a block with
# no present keys is an open map; the resolver AFTER, to the merged
# instance, because an absent key must stay absent through the merge.
BLOCK_DEFAULTS = {
    'active': lambda: True,
    'feature': lambda: {},
}

# The one block key carrying the timing rule. Named rather than
# inferred, so a reader does not have to work out which of the two it
# is, and so a port can assert it.
MERGE_SENSITIVE = ['active']


# ---------------------------------------------------------------------
# normalize_config
# ---------------------------------------------------------------------

def normalize_config(raw):
    """Materialize every documented default, DEFENSIVELY: a node that is
    not the kind it expects is left alone for validate to reject with a
    proper message. Pure data-in/data-out, which is what makes it
    portable to sixteen languages and expressible in the corpus.

    THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE,
    and the input is never mutated: every map is copied before writing."""
    if not _ismap(raw):
        return raw
    out = dict(raw)

    if 'station' not in out:
        out['station'] = 1
    if 'profiles' not in out:
        out['profiles'] = {}
    if not _ismap(out['profiles']):
        return out

    profiles = {}
    for pname, p in out['profiles'].items():
        if not _ismap(p):
            profiles[pname] = p
            continue
        prof = dict(p)

        for k, mk in PROFILE_DEFAULTS.items():
            if k not in prof:
                prof[k] = mk()
        # A `secrets` written without `providers` still gets the chain.
        if _ismap(prof['secrets']) and 'providers' not in prof['secrets']:
            secrets = dict(prof['secrets'])
            secrets['providers'] = [{'kind': 'env'}]
            prof['secrets'] = secrets
        prof['feature'] = _normfeatures(prof['feature'])

        for bkey in ('api', 'sdk'):
            if not _ismap(prof.get(bkey)):
                continue
            blocks = {}
            for ref, b in prof[bkey].items():
                if not _ismap(b):
                    blocks[ref] = b
                    continue
                block = dict(b)
                for k, mk in BLOCK_DEFAULTS.items():
                    if k not in block:
                        block[k] = mk()
                block['feature'] = _normfeatures(block['feature'])
                blocks[ref] = block
            prof[bkey] = blocks

        profiles[pname] = prof
    out['profiles'] = profiles
    return out


def _normfeatures(f):
    """Per feature entry, at every level: `active` -> True.

    A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
    own default is `active: false` for all but `log`, and
    `{"retry": {"retries": 3}}` plainly means "retry, with three
    attempts". It also keeps the feature map closed, for the same reason
    every other block needs one present key.

    Defensive like the rest: a non-map is returned untouched for validate
    to reject by path."""
    if not _ismap(f):
        return f
    out = {}
    for name, e in f.items():
        if _ismap(e) and 'active' not in e:
            e = dict(e)
            e['active'] = True
        out[name] = e
    return out


# ---------------------------------------------------------------------
# validate_config
# ---------------------------------------------------------------------

# `spec/config-shape.json`, design 4.3 verbatim - the artifact every port
# reads. This port runs straight from the repo (like omnihome's
# specfile), so it reads the JSON itself rather than shipping a mirror
# the way a compiled or published artifact must.
_CONFIG_SHAPE = None


def config_shape():
    """A FRESH DEEP COPY of the shape, every call: struct's validate
    consumes the spec it walks (it deletes satisfied `$ONE` branches as
    it goes), so handing it the parsed constant twice would validate the
    second config against a spec the first had already eaten."""
    global _CONFIG_SHAPE
    if _CONFIG_SHAPE is None:
        file = os.path.abspath(
            os.path.join(_HERE, '..', '..', 'spec', 'config-shape.json'))
        with open(file, encoding='utf-8') as handle:
            _CONFIG_SHAPE = json.load(handle)
    return _struct().clone(_CONFIG_SHAPE)


# Credential-shaped keys (design 5.2). `secret` is here AND is the one
# exempt key - see _secretvalue below; a blanket deny would reject the
# very mechanism that keeps values out of the file.
_CREDENTIAL_KEYS = (
    'apikey', 'auth', 'authorization', 'token',
    'secret', 'password', 'credential', 'bearer',
)

# The suffix rule catches `access_key`, `X-Api-Token` and friends in one
# rule rather than a growing list of spellings.
_CREDENTIAL_SUFFIX = ('_KEY', '_TOKEN', '_SECRET', '_PASSWORD')

# design 5.2's backstop, and it is stated as one rather than as a
# grammar. `validname()` is a NAME grammar, not a credential filter: it
# rejects uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
# credential formats - but a lowercase hex token passes it cleanly. A
# character class cannot tell a name from a secret.
#
# Derived names break on every separator (`voxgig_solardemo.apikey` runs
# 6/9/6) and a hand-written name for a human to read does too; a
# 24-character unbroken run is not a name anybody writes. Note this is a
# RUN bound, not a length bound: `acme_internal_billing_service.apikey`
# is 36 characters and passes, which is the false positive a naive
# length bound would produce.
_RUN_BOUND = 24
_UNBROKEN_RUN = re.compile('[A-Za-z0-9]{' + str(_RUN_BOUND) + ',}')

_SCHEME = re.compile(r'^[a-zA-Z][a-zA-Z0-9+.-]*://')

_NONALNUM = re.compile(r'[^a-z0-9]+')


def validate_config(normalized):
    """Normalize, then validate (design 4.2). Raises
    station_config_invalid with EVERY struct error at once - an
    eighteen-instance config that touches three of them must not die
    because the eighteenth has a typo'd package name - then the 5.2
    scans.

    The 4.4 workarounds are merged into the SAME throw as struct's own
    errors: a struct new enough to reject a first-element gap itself
    reports a DIFFERENT spelling ("to be one of ..."), and the corpus
    pins the explicit one - so the pinned message is produced here
    either way, and behavior is identical whatever struct version
    resolves.

    Takes the NORMALIZED form. Handing it a raw config is the mistake
    4.2 exists to prevent, so callers go through open()/normalize_config."""
    errs = []
    _struct().validate(normalized, config_shape(), {'errs': errs})

    secrets, reserved, invalid = _scan_config(normalized)

    if 0 < len(errs) or 0 < len(invalid):
        raise StationError(
            'station_config_invalid',
            '; '.join(errs + invalid) + _renamehint(normalized))
    if 0 < len(reserved):
        raise StationError('station_feature_reserved', '; '.join(reserved))
    if 0 < len(secrets):
        raise StationError('station_config_secret', '; '.join(secrets))
    return normalized


def _renamehint(cfg):
    """`plugin` is REMOVED, not aliased (design 3.4) - a deprecated alias
    would be a second grammar for one concept in sixteen ports. The shape
    already rejects it as an unexpected key; this says what to rename,
    because "unexpected key: plugin" alone does not, and the migration
    for a single-instance project is exactly this one rename."""
    profiles = cfg.get('profiles') if _ismap(cfg) else None
    profiles = profiles if _ismap(profiles) else {}
    hit = [p for p in profiles
           if _ismap(profiles[p]) and 'plugin' in profiles[p]]
    if 0 == len(hit):
        return ''
    return ('; rename `plugin` to `sdk` in ' +
            ', '.join('profiles.' + p for p in hit) +
            ' - the keys are unchanged, an untagged ref IS an api slug (3.4)')


def _scan_config(cfg):
    """The 5.2 scans, over the parts of the grammar that hold arbitrary
    data. Everything else is closed by construction and needs no scan -
    `profiles.<p>.secrets.providers` INCLUDED: a provider block
    legitimately carries an `auth` sub-map ({method, role}), so the scan
    deliberately does not reach there. Collects rather than throws;
    validate_config owns the throw order."""
    secrets = []
    reserved = []
    invalid = []

    profiles = cfg.get('profiles') if _ismap(cfg) else None
    profiles = profiles if _ismap(profiles) else {}
    for pname, prof in profiles.items():
        if not _ismap(prof):
            continue
        ppath = 'profiles.' + pname

        _scanfeatures(prof.get('feature'), ppath + '.feature',
                      secrets, reserved, invalid)

        for bkey in ('api', 'sdk'):
            if not _ismap(prof.get(bkey)):
                continue
            for ref, block in prof[bkey].items():
                if not _ismap(block):
                    continue
                bpath = ppath + '.' + bkey + '.' + ref

                # The block's own `secret` holds a NAME. resolve_profile
                # checks it again per instance (station_secret_name);
                # this catches it at open(), for the whole file at once.
                if 'secret' in block:
                    _secretvalue(block['secret'], bpath + '.secret', secrets)

                # `options` is passthrough to a generated constructor, so
                # it is the one place a value can hide.
                _scan(block.get('options'), bpath + '.options',
                      secrets, reserved)
                _scanfeatures(block.get('feature'), bpath + '.feature',
                              secrets, reserved, invalid)

                # design 4.4's explicit checks, applied where the shape
                # cannot reach, raising the same code the shape would -
                # and pinned in the corpus so each workaround is removed
                # deliberately when struct is fixed rather than forgotten.
                _checkpolicy(block.get('policy'), bpath + '.policy', invalid)

    return secrets, reserved, invalid


def _scanfeatures(f, path, secrets, reserved, invalid):
    """A feature map at any level. `station` is reserved: station
    composes its own wrap and a config that reconfigures it is asking for
    a state the ordering rules cannot express (design 8.4)."""
    if not _ismap(f):
        return
    for name, entry in f.items():
        fpath = path + '.' + name
        if 'station' == name:
            reserved.append(
                path + '.station is reserved: station composes its own wrap '
                'and it cannot be configured from station.json')
        order = entry.get('order') if _ismap(entry) else None
        if _ismap(order):
            _firstelement(order.get('before'),
                          fpath + '.order.before', invalid)
            _firstelement(order.get('after'),
                          fpath + '.order.after', invalid)
        _scan(entry, fpath, secrets, reserved)


# The policy block's 4.4 workarounds, in one place because they are one
# class of gap: struct cannot check what its own defects hide.
#
#  - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists, so
#    element 0 escapes the shape (see _firstelement below).
#  - `budget` is a map whose keys are ALL optional scalars, and struct
#    removes an unsatisfied optional key from the spec node - so
#    `budget: {rp: 1}` degenerates the spec into an open map and the typo
#    passes. `allow` does not have this problem (its `$CHILD` keys stay
#    in the spec whether or not the data carries them, keeping the map
#    closed), and neither does `policy` itself (`hosts` anchors it);
#    `budget` alone needs the explicit unexpected-key check, phrased as
#    struct would phrase it.
_BUDGET_KEYS = ('concurrency', 'rps')


def _checkpolicy(policy, path, invalid):
    if not _ismap(policy):
        return

    _firstelement(policy.get('hosts'), path + '.hosts', invalid)

    allow = policy.get('allow')
    if _ismap(allow):
        _firstelement(allow.get('op'), path + '.allow.op', invalid)
        _firstelement(allow.get('method'), path + '.allow.method', invalid)

    budget = policy.get('budget')
    if _ismap(budget):
        unknown = sorted(k for k in budget if k not in _BUDGET_KEYS)
        if 0 < len(unknown):
            invalid.append('Unexpected keys at field ' + path + '.budget: ' +
                           ', '.join(unknown))


def _firstelement(value, path, invalid):
    """design 4.4: `$CHILD` in list mode DOES NOT VALIDATE ELEMENT 0.
    Verified: `["a", 1]` fails at index 1, `[1]` passes, at any list
    length - filed upstream as voxgig/struct#113. It reaches THREE string
    lists in this shape: `policy.hosts`, and the per-feature
    `order.before` / `order.after`. Applied where the shape cannot reach,
    raising the same code the shape would, and pinned in the corpus so
    the workaround is removed deliberately when struct is fixed rather
    than forgotten."""
    if not isinstance(value, list) or 0 == len(value):
        return
    if isinstance(value[0], str):
        return
    invalid.append('Expected field ' + path + '.0 to be string, but found ' +
                   _kindof(value[0]) + ': ' + _json(value[0]))


def _scan(node, path, secrets, reserved):
    """Recursive over EVERY nested map and list, not just the top level -
    a credential one level down is the case a top-level scan misses."""
    if isinstance(node, list):
        for i, item in enumerate(node):
            _scan(item, path + '.' + str(i), secrets, reserved)
        return
    if isinstance(node, str):
        _userinfo(node, path, secrets)
        return
    if not _ismap(node):
        return

    for key, val in node.items():
        kpath = path + '.' + str(key)

        # design 8.6: station owns feature composition, so an
        # `options.feature` in a declarative config is a second,
        # unreconciled ordering input.
        if 'feature' == key:
            reserved.append(
                kpath + ' is reserved: configure features under the block\'s '
                'own `feature` key, not through `options`')
            continue

        if 'secret' == str(key).lower():
            _secretvalue(val, kpath, secrets)
            continue

        if _credentialkey(key):
            secrets.append(
                kpath + ' is a credential-shaped key: station.json holds '
                'secret NAMES, never values (5.2)')
            continue

        _scan(val, kpath, secrets, reserved)


def _credentialkey(key):
    low = _NONALNUM.sub('', str(key).lower())
    if low in _CREDENTIAL_KEYS:
        return True
    tok = envtoken(key)
    return any(tok.endswith(s) for s in _CREDENTIAL_SUFFIX)


def _secretvalue(val, path, secrets):
    """A `secret`-named key holds a NAME, and that exemption is not a
    loophole - it is the whole design. THREE checks, not one, and they
    live in the same handful of lines precisely so a port cannot
    implement only the first and inherit the gap the others close."""
    if not isinstance(val, str):
        secrets.append(path + ' must be a secret name (a string), but found ' +
                       _kindof(val))
        return
    if not validname(val):
        secrets.append(path + ' is not a valid sekreto name, so it cannot be '
                       'a name and must not be a value: ' + _json(val))
        return
    if _UNBROKEN_RUN.search(val):
        secrets.append(path + ' contains an unbroken alphanumeric run of ' +
                       str(_RUN_BOUND) + ' or more characters, which is not a '
                       'name anybody writes')


def _userinfo(val, path, secrets):
    """One rule about values rather than keys, because the `proxy`
    feature makes it concrete: `http://user:pass@proxy.internal:8080`.
    A parse failure is not an error - it returns silently."""
    if not _SCHEME.match(val):
        return
    try:
        authority = val.split('://', 1)[1]
        for cut in ('/', '?', '#'):
            at = authority.find(cut)
            if -1 != at:
                authority = authority[:at]
        info = authority.rpartition('@')[0]
    except Exception:
        return
    if '' != info:
        secrets.append(
            path + ' is a URL carrying userinfo, which puts a credential in '
            'the config file; use the proxy feature\'s `fromEnv` option '
            'instead (8.6)')


def _kindof(v):
    """The SHAPE kindof, which must agree with struct's own spellings.
    NOT the feature one in feature.py - the two disagree on numbers and
    maps on purpose, and unifying them would report struct's grammar in
    the SDK's words."""
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'boolean'
    if isinstance(v, list):
        return 'list'
    if isinstance(v, (int, float)):
        return 'integer' if float(v).is_integer() else 'decimal'
    if isinstance(v, dict):
        return 'object'
    if isinstance(v, str):
        return 'string'
    return type(v).__name__.lower()


def _json(v):
    # JSON.stringify's spacing, so the pinned messages read the same in
    # every port.
    return json.dumps(v, ensure_ascii=False, separators=(',', ':'))


def _ismap(v):
    return isinstance(v, dict)
