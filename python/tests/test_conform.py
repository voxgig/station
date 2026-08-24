# RUN: python3 -m unittest discover -s tests
# RUN-SOME: python3 -m unittest discover -s tests -k secretname
#
# The station conformance suite: the pure-contract half of the design's
# station.md 13 corpus, from spec/station.json, through voxgig/omni -
# the same file every port runs. Sections that need live SDK machinery
# (inject, order, event correlation) live in the integration suites
# against real generated SDKs; the corpus carries what a port can prove
# with no SDK present.

import json
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))


def _sibling(name):
    """A sibling multi-port checkout (omni, sekreto), not yet published."""
    cands = [
        os.environ.get(name.upper() + '_HOME'),
        os.path.join(_HERE, '..', '..', '..', name),
        os.path.join(_HERE, '..', '..', '..', '..', name),
        '/workspace/' + name,
        '/home/user/' + name,
    ]
    for cand in cands:
        if cand and os.path.isdir(os.path.join(cand, 'python')):
            return os.path.abspath(cand)
    raise FileNotFoundError('station: voxgig/' + name + ' not found - set ' +
                            name.upper() + '_HOME')


# omni and sekreto are sibling checkouts, not published packages (yet).
# struct is one too, but the library finds it itself (structhome.py): it
# is a RUNTIME dependency, not a test one.
sys.path.insert(0, os.path.join(_sibling('omni'), 'python'))
if 'voxgig_sekreto' not in sys.modules:
    try:
        import voxgig_sekreto  # noqa: F401
    except ImportError:
        sys.path.insert(0, os.path.join(_sibling('sekreto'), 'python'))

from voxgig_omni import NULLMARK, makeRunner  # noqa: E402

from voxgig_sekreto import envkey  # noqa: E402

from voxgig_station import (  # noqa: E402
    canonical_serialize,
    check_pin,
    envtoken,
    feature_sources,
    instance_ref,
    is_known_code,
    merge_features,
    normalize_config,
    normalize_descriptor,
    placeholder_for,
    resolve_order,
    resolve_profile,
    secretname_default,
    validate_config,
)
from voxgig_station.omnihome import specfile  # noqa: E402


def denull(v):
    """Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
    subject sees what the spec means."""
    if NULLMARK == v:
        return None
    if isinstance(v, list):
        return [denull(x) for x in v]
    if isinstance(v, dict):
        return {k: denull(x) for k, x in v.items()}
    return v


def _secretname(vin):
    secretname = secretname_default(vin['slug'])
    return {
        'envtoken': envtoken(vin['slug']),
        'secretname': secretname,
        'envkey': envkey(secretname),
    }


def _feature(vin):
    """design 8's pure half (10.1): the three-level merge with its depth
    boundary, and the 8.4 order resolution. ONE DRIVER, TWO ENTRY SHAPES
    - `merged` selects the resolver, anything else the merge - because a
    port that guessed from looser cues would run the wrong subject on a
    mistyped entry."""
    if vin.get('merged') is not None:
        ordered = resolve_order(denull(vin['merged']))
        check_pin(ordered)
        return [o['name'] for o in ordered]
    return merge_features(feature_sources(
        denull(vin.get('base')), denull(vin.get('overlay')),
        vin.get('api'), vin.get('ref')))


# One driver per section this port RUNS, keyed by the corpus section
# name - the tests below are REGISTERED from this table, so a section
# listed here cannot silently not run, and the completeness guard closes
# the other direction.
DRIVERS = {
    'secretname': _secretname,

    'placeholder': placeholder_for,

    'descriptor': lambda vin: normalize_descriptor(
        vin['config'], vin['feature'])[0],

    'descriptorwarnings': lambda vin: len(normalize_descriptor(
        vin['config'], vin['feature'])[1]),

    'canonical': lambda vin: canonical_serialize(denull(vin)),

    # Normalize, then validate (design 4.2). The entry is a RAW config
    # in, and either the normalized output or the expected error out -
    # the two steps are one pipeline and a port that splits them is free
    # to validate the wrong form.
    'config': lambda vin: validate_config(normalize_config(denull(vin))),

    # The 3.3 merge, and the whole of this port's profile contract.
    'instance': lambda vin: resolve_profile(denull(vin['config']),
                                            vin['profile']),

    'feature': _feature,

    # 6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
    # rather than driver-shaped even though it decides a registry key.
    'instanceref': lambda vin: instance_ref(vin['api'], vin['opts']),

    'errors': is_known_code,
}

# The sections this port deliberately does NOT run, with the reason - an
# entry here is a decision, not an omission.
PENDING = {
    # Pins the pre-Stage-1 `plugin` grammar, which this port no longer
    # speaks. It stays in the corpus for the ports that have not crossed
    # the rename yet and is deleted when the last one does - see
    # spec/README.md. Everything it pins is restated in the sdk/api
    # grammar the `instance` section runs.
    'profile': 'pre-rename plugin grammar; superseded by the instance section',
}


runner = makeRunner(specfile())
R = runner('station')

spec = R['spec']
runset = R['runset']


class TestStationConform(unittest.TestCase):

    def test_sections_covered(self):
        """Section completeness: the sections run plus the explicit
        PENDING list must exactly cover what spec/station.json carries. A
        section added to the corpus and not picked up here fails loudly
        instead of silently not running. Read as RAW JSON, not through
        the runner: the runner resolves a named section and would hide
        one it never resolved."""
        with open(specfile(), encoding='utf-8') as handle:
            raw = json.load(handle)
        present = sorted(raw['primary']['station'].keys())
        covered = sorted(list(DRIVERS.keys()) + list(PENDING.keys()))
        self.assertEqual(present, covered)


def _register(section, driver):
    def run(self):
        self.assertIsNotNone(spec.get(section),
                             'corpus section missing: ' + section)
        runset(spec[section], driver)
    run.__name__ = 'test_' + section
    return run


# REGISTERED FROM THE TABLE, never written out by hand: a section in
# DRIVERS cannot silently fail to execute, because the test either
# exists and runs or the table does not name it - and then
# test_sections_covered catches that instead.
for _section, _driver in DRIVERS.items():
    setattr(TestStationConform, 'test_' + _section, _register(_section, _driver))


if __name__ == '__main__':
    unittest.main()
