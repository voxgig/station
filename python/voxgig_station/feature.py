# Feature management (design station.md 8): the three-level merge, the
# constraint-and-band resolver, and the descriptor-derived checker.
#
# The resolver is written to voxgig/plugin's 7 semantics so plugin can
# extract it - this is one of the pieces the joint plan means by
# "station builds natively to plugin's semantics".
#
# A port of typescript/src/feature.ts, which is canonical.

import json

from .error import StationError

# ---------------------------------------------------------------------
# design 8.3 - the merge
# ---------------------------------------------------------------------

# Reserved on a feature entry: not options, and never passed through to
# the SDK's own option map.
RESERVED_KEYS = ['active', 'order']


def merge_features(sources):
    """The six sources, in 3.3's order extended by the profile level:

      1 base.feature            4 overlay.feature
      2 base.api[<api>].feature 5 overlay.api[<api>].feature
      3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature

    PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
    the narrower block wins - the same principle as 3.3, one level down.

    `feature` is the ONE key where 3.3's shallow-per-key rule is wrong:
    composition is the entire point, a fleet default plus a per-instance
    tweak. So it is a TWO-LEVEL merge - per feature name, then per option
    key - and no deeper. A map-valued option REPLACES wholesale, which is
    what `{"$MERGE": {"deep": 2}}` states and what a port defaulting to a
    deep merge would silently get wrong.

    Same defaults-after-merge rule as 3.3, one level down: an entry
    mentioned at one level with only a tuning key must NOT synthesize
    `active` and switch on a feature a broader level turned off. That is
    the 3.3 defect one level down, and it is why the caller passes RAW
    blocks here."""
    out = {}
    for src in sources:
        if not _ismap(src):
            continue
        for name, entry in src.items():
            if not _ismap(entry):
                out[name] = entry
                continue
            # Per option key, and NOT deeper.
            prior = out.get(name)
            merged = dict(prior) if _ismap(prior) else {}
            merged.update(entry)
            out[name] = merged
    return out


def feature_sources(base, overlay, api, ref):
    """The six sources for one instance, in order. Assembled here rather
    than at the call site so the order lives in exactly one place."""
    return [
        _at(base, 'feature'),
        _at(_at(_at(base, 'api'), api), 'feature'),
        _at(_at(_at(base, 'sdk'), ref), 'feature'),
        _at(overlay, 'feature'),
        _at(_at(_at(overlay, 'api'), api), 'feature'),
        _at(_at(_at(overlay, 'sdk'), ref), 'feature'),
    ]


def _at(node, key):
    return node.get(key) if _ismap(node) else None


# ---------------------------------------------------------------------
# design 8.4 - activation and order
# ---------------------------------------------------------------------

# `test` substitutes the base transport, so it takes the innermost band;
# `station` sits immediately outside it, pinned; everything else is band
# 0, outside station.
#
# THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
# than as a special case: a project that writes no `order` anywhere sees
# exactly today's nesting, and sdkgen's two `makeOptions` special cases
# become two band values rather than two branches.
BAND_DEFAULT = 0
BAND_STATION = 100
BAND_TEST = 200


def default_band(name):
    """Higher is further IN."""
    if 'test' == name:
        return BAND_TEST
    if 'station' == name:
        return BAND_STATION
    return BAND_DEFAULT


def resolve_order(merged):
    """Resolve the activation order: constraints, then bands, then the
    feature's position in the merged map.

    `before`/`after` take a feature name or a list of them and are
    SATISFIED VACUOUSLY when the named feature is absent - `after: 'test'`
    loads fine in a project with no test feature, which is sdkgen's
    `__after__` behaviour kept rather than reinvented.

    Constraints beat bands; bands break ties no constraint decides;
    remaining ties break by declaration position, so the result is a
    stable topological sort with no alphabetical accident in it.

    Returns OUTERMOST FIRST, which is the array form the constructor
    takes and the direction plugin's chain composes in."""
    names = [n for n in merged if active(merged[n])]
    pos = {n: i for i, n in enumerate(names)}

    band = {}
    for n in names:
        o = merged[n].get('order') if _ismap(merged[n]) else None
        b = o.get('band') if _ismap(o) else None
        band[n] = b if _isnum(b) else default_band(n)

    # edges: from OUTER to INNER. `after: X` means "further in than X".
    inner = {n: [] for n in names}

    for n in names:
        o = merged[n].get('order') if _ismap(merged[n]) else None
        if not _ismap(o):
            continue
        # Vacuous when absent: an unknown name is not an error here.
        for other in _listof(o.get('after')):
            if other in inner and n not in inner[other]:
                inner[other].append(n)
        for other in _listof(o.get('before')):
            if other in inner and other not in inner[n]:
                inner[n].append(other)

    indeg = {n: 0 for n in names}
    for n in names:
        for m in inner[n]:
            indeg[m] += 1

    # Kahn, picking the lowest band first (outermost), then declaration
    # position - so ties break the same way in every port.
    ready = [n for n in names if 0 == indeg[n]]
    out = []
    while 0 < len(ready):
        ready.sort(key=lambda n: (band[n], pos[n]))
        n = ready.pop(0)
        out.append({'name': n, 'band': band[n], 'entry': merged[n]})
        for m in inner[n]:
            indeg[m] -= 1
            if 0 == indeg[m]:
                ready.append(m)

    if len(out) != len(names):
        done = set(o['name'] for o in out)
        stuck = sorted(n for n in names if n not in done)
        raise StationError(
            'station_feature_order',
            'feature ordering constraints form a cycle among [' +
            ', '.join(stuck) + ']')

    return out


def active(entry):
    """A feature named in the config is one you are ASKING for, so an
    entry with no `active` is active."""
    if not _ismap(entry):
        return False is not entry
    return False is not entry.get('active')


def check_pin(ordered):
    """Station's own position is PINNED and not orderable (design 8.4):
    an order that moves `station` away from immediately-outside-the-base
    is REJECTED, not honoured.

    The pin is `innermost`, and the spelling matters. A chain composes
    with the FIRST binding outermost, so a pin written in sort terms -
    "station first" - would place every other wrapper between the adapter
    and the base: the exact inversion of the invariant, and one that
    would leave station's wire-truth events observing the wrong boundary
    while still looking ordered."""
    i = _indexof(ordered, 'station')
    if -1 == i:
        return

    base = _indexof(ordered, 'test')
    # station must be the innermost wrapper: last, or immediately outside
    # the base-transport feature when one is active.
    want = len(ordered) - 1 if -1 == base else base - 1
    if i != want:
        raise StationError(
            'station_feature_order',
            'an ordering would move `station` away from immediately outside '
            'the base transport; its position is pinned innermost and is not '
            'orderable (8.4)')


def compose_features(ordered):
    """Compose the merged map into the ORDERED ARRAY FORM the constructor
    takes. No new seam: it is what `connect()` already does for station's
    own placement, with more in it."""
    out = []
    for o in ordered:
        entry = o['entry'] if _ismap(o['entry']) else {}
        row = {'name': o['name'], 'active': True}
        for k, v in entry.items():
            if k in RESERVED_KEYS:
                continue
            row[k] = v
        out.append(row)
    return out


# ---------------------------------------------------------------------
# design 8.5 - the checker, derived from the descriptor
# ---------------------------------------------------------------------

def check_features(merged, descriptor):
    """Check a merged feature map against the SDK'S OWN DECLARATION.

    The schema arrives with the FACTORY rather than with a live client
    (6.2), so this needs no construction and no network - which is what
    lets `check()` run it for every instance in CI.

    Derived from the descriptor, never hand-written, so it cannot drift:
    when a feature gains an option, the next regeneration teaches station
    about it with no station change.

    SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED, and
    that limit is real. An empty list default says nothing reliable about
    its element type and a nested map default says nothing about its
    value shapes, so `methods: [{}]` against a `['GET']` default is
    caught while `noProxy: []` accepts anything list-shaped.

    COLLECTS, never throws - the callers own the throw."""
    faults = []
    declared = (descriptor or {}).get('features') or []
    byname = {}
    for f in declared:
        if _ismap(f):
            byname[str(f.get('name'))] = f

    for name in sorted(merged.keys()):
        spec = byname.get(name)
        if spec is None:
            faults.append({
                'code': 'station_feature_unknown',
                'feature': name,
                'message': 'the SDK has no feature "' + name + '"; it '
                           'declares [' + ', '.join(sorted(byname.keys())) + ']',
            })
            continue

        entry = merged[name]
        if not _ismap(entry):
            continue
        defaults = spec['options'] if _ismap(spec.get('options')) else {}

        for key in sorted(entry.keys()):
            if key in RESERVED_KEYS:
                continue

            if key not in defaults:
                # THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is
                # accepted and silently ignored today, because the SDK's
                # own feature spec is `$OPEN` per feature so the SDK
                # cannot catch it and nothing else looks.
                faults.append({
                    'code': 'station_feature_option',
                    'feature': name,
                    'key': key,
                    'message': 'feature "' + name + '" declares no option "' +
                               key + '"; it declares [' +
                               ', '.join(sorted(defaults.keys())) + ']',
                })
                continue

            want = _kindof(defaults[key])
            got = _kindof(entry[key])
            if want != got:
                faults.append({
                    'code': 'station_feature_option',
                    'feature': name,
                    'key': key,
                    'message': 'feature "' + name + '" option "' + key +
                               '" expects ' + want + ', but found ' + got +
                               ': ' + _json(entry[key]),
                })

    return faults


def _json(v):
    # JSON.stringify's spacing, so the pinned messages read the same in
    # every port.
    return json.dumps(v, ensure_ascii=False, separators=(',', ':'))


def _kindof(v):
    """The FEATURE kindof. NOT the shape one in shape.py: that one speaks
    struct's grammar (integer/decimal, object), this one the SDK's."""
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'boolean'
    if isinstance(v, list):
        return 'list'
    if isinstance(v, (int, float)):
        return 'number'
    if isinstance(v, dict):
        return 'map'
    if isinstance(v, str):
        return 'string'
    return type(v).__name__.lower()


def _listof(v):
    if v is None:
        return []
    return [str(x) for x in (v if isinstance(v, list) else [v])]


def _indexof(ordered, name):
    for i, o in enumerate(ordered):
        if name == o['name']:
            return i
    return -1


def _isnum(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _ismap(v):
    return isinstance(v, dict)
