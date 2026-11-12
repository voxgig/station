# RUN: python3 -m unittest discover -s tests
#
# A port of typescript/test/exposure.test.ts, which is canonical.

import json
import os
import pprint
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..'))

try:
    import voxgig_sekreto  # noqa: F401
except ImportError:
    for name in ('plugin', 'sekreto'):
        for cand in (os.path.join(_HERE, '..', '..', '..', name),
                     os.path.join(_HERE, '..', '..', '..', '..', name),
                     '/workspace/' + name, '/home/user/' + name):
            if os.path.isdir(os.path.join(cand, 'python')):
                sys.path.insert(0, os.path.abspath(os.path.join(cand, 'python')))
                break

from voxgig_station import Station  # noqa: E402

SECRET = 'exposure-key-101'

CONFIG = {
    'main': {'name': 'taskpad', 'slug': 'taskpad', 'version': '1.0.0', 'target': 'py'},
    'options': {'base': 'http://api.test', 'auth': {'prefix': ''}, 'entity': {}},
    'entity': {},
}


class Utility:
    def __init__(self):
        self.fetcher = lambda _c, _url, _def: ({'status': 200, 'headers': {}}, None)


class Ctx:
    def __init__(self, client, utility, options):
        self.client = client
        self.utility = utility
        self.options = options
        self.config = CONFIG
        self.op = None
        self.entity = None
        self.result = None


class SDK:
    """An SDK generated without the station feature, reduced to what the
    carried adapter touches: the options kept as given, extend features
    initialised in order, and a transport that answers 200."""

    def __init__(self, options):
        self.options = options
        self.mode = 'live'
        self.features = []
        self.utility = Utility()
        self.ctx = Ctx(self, self.utility, options)
        for f in options.get('extend') or []:
            self.features.append(f)
            f.init(self.ctx, (options.get('feature') or {}).get(f.name) or {})

    def call(self):
        return self.utility.fetcher(self.ctx, 'http://api.test/todo', {
            'method': 'GET', 'headers': {'authorization': self.options['apikey']}})


def shows(value):
    return json.dumps(value, default=repr) + pprint.pformat(value)


def reaches_station(value, seen=None):
    seen = set() if seen is None else seen
    if isinstance(value, Station):
        return True
    if id(value) in seen:
        return False
    seen.add(id(value))
    if isinstance(value, dict):
        return any(reaches_station(v, seen) for v in value.values())
    if isinstance(value, (list, tuple)):
        return any(reaches_station(v, seen) for v in value)
    return False


class TestExposure(unittest.TestCase):

    def setUp(self):
        Station.reset()
        os.environ['TASKPAD_APIKEY'] = SECRET

    def tearDown(self):
        Station.reset()
        os.environ.pop('TASKPAD_APIKEY', None)

    def test_a_bound_clients_options_hold_no_secret_after_a_live_request(self):
        st = Station.open({'config': None})
        client = st.connect(SDK)
        res, err = client.call()
        self.assertIsNone(err)
        self.assertEqual(200, res['status'])

        self.assertNotIn(SECRET, shows(client.options))
        self.assertFalse(reaches_station(client.options), 'the options reach no Station')
        st.close()

    def test_the_callers_own_key_does_not_ride_the_activation_entry(self):
        os.environ.pop('TASKPAD_APIKEY', None)
        st = Station.open({'config': None})
        client = st.adopt(SDK, {'apikey': SECRET})
        client.call()

        self.assertNotIn(SECRET, shows(client.options))
        st.close()

    def test_inverted_binding_the_activation_entry_holds_neither(self):
        st = Station.open({'config': None})
        options = st.options({'apikey': SECRET})

        self.assertEqual(SECRET, options['apikey'], 'the SDK still gets the key it is given')
        self.assertNotIn(SECRET, shows(options['feature']['station']))
        self.assertFalse(reaches_station(options), 'the options reach no Station')
        st.close()


if __name__ == '__main__':
    unittest.main()
