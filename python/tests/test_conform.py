# RUN: python3 -m unittest discover -s tests
# RUN-SOME: python3 -m unittest discover -s tests -k secretname
#
# The station conformance suite: the pure-contract half of the design's
# station.md 13 corpus, from spec/station.json, through voxgig/omni -
# the same file every port runs. Sections that need live SDK machinery
# (inject, order, event correlation) live in the integration suites
# against real generated SDKs; the corpus carries what a port can prove
# with no SDK present.

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
    envtoken,
    is_known_code,
    normalize_descriptor,
    placeholder_for,
    resolve_profile,
    secretname_default,
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


runner = makeRunner(specfile())
R = runner('station')

spec = R['spec']
runset = R['runset']


class TestStationConform(unittest.TestCase):

    def test_secretname(self):
        def subject(vin):
            secretname = secretname_default(vin['slug'])
            return {
                'envtoken': envtoken(vin['slug']),
                'secretname': secretname,
                'envkey': envkey(secretname),
            }
        runset(spec['secretname'], subject)

    def test_placeholder(self):
        runset(spec['placeholder'], placeholder_for)

    def test_descriptor(self):
        runset(spec['descriptor'], lambda vin:
               normalize_descriptor(vin['config'], vin['feature'])[0])

    def test_descriptorwarnings(self):
        runset(spec['descriptorwarnings'], lambda vin:
               len(normalize_descriptor(vin['config'], vin['feature'])[1]))

    def test_canonical(self):
        runset(spec['canonical'], lambda vin: canonical_serialize(denull(vin)))

    def test_profile(self):
        runset(spec['profile'], lambda vin:
               resolve_profile(denull(vin['config']), vin['profile']))

    def test_errors(self):
        runset(spec['errors'], is_known_code)


if __name__ == '__main__':
    unittest.main()
