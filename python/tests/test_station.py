# RUN: python3 -m unittest discover -s tests
#
# Focused unit tests for the py port: the ambient contract, the secret
# broker's miss-vs-error distinction and exact-value scrub, the event
# ring, and the binding path (wrap position, placeholder planting,
# copy-on-inject, mock non-injection, hosts policy) against a faithful
# miniature of the py SDK's seams. Integration against a REAL generated
# SDK lives in the consumer validation flow, not here.

import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..'))

try:
    import voxgig_sekreto  # noqa: F401
except ImportError:
    for cand in (os.path.join(_HERE, '..', '..', '..', 'sekreto'),
                 '/workspace/sekreto', '/home/user/sekreto'):
        if os.path.isdir(os.path.join(cand, 'python')):
            sys.path.insert(0, os.path.abspath(os.path.join(cand, 'python')))
            break

from voxgig_station import (  # noqa: E402
    Station,
    StationError,
    adapter_feature,
    feature_binding,
    placeholder_for,
)
from voxgig_station.events import EventBuffer  # noqa: E402
from voxgig_station.secrets import SecretBroker  # noqa: E402


CONFIG = {
    'main': {'name': 'GnarlyPets', 'slug': 'gnarly-pets',
             'version': '0.0.1', 'target': 'py'},
    'feature': {'test': {}},
    'options': {
        'base': 'http://localhost:8903',
        'auth': {'prefix': 'Bearer'},
        'entity': {'pet': {}},
    },
    'entity': {'pet': {'name': 'pet', 'fields': [], 'op': {
        'load': {'points': [{'method': 'GET', 'orig': '/api/pet/:pet_id',
                             'parts': ['api', 'pet', ':pet_id']}]}}}},
}


class FakeUtility:
    def __init__(self, fetcher):
        self.fetcher = fetcher


class FakeClient:
    def __init__(self, mode='live'):
        self.mode = mode
        self.features = []


class FakeCtx:
    """The slice of the py SDK context the binding touches."""

    def __init__(self, client, utility, options, config=CONFIG):
        self.client = client
        self.utility = utility
        self.options = options
        self.config = config
        self.op = None
        self.entity = None
        self.result = None


def base_fetcher(log):
    def fetch(fctx, fullurl, fetchdef):
        log.append({'url': fullurl, 'fetchdef': fetchdef})
        return {'status': 200, 'statusText': 'OK',
                'headers': {'content-length': '2'},
                'json': lambda: [], 'body': '[]'}, None
    return fetch


def bind(station, mode='live', options=None, config=CONFIG, log=None):
    log = [] if log is None else log
    client = FakeClient(mode)
    utility = FakeUtility(base_fetcher(log))
    options = {'apikey': ''} if options is None else options
    ctx = FakeCtx(client, utility, options, config)
    adapter = adapter_feature(station, None)
    client.features.append(adapter)
    adapter.init(ctx, {'active': True})
    return ctx, log


class TestAmbient(unittest.TestCase):

    def setUp(self):
        Station.reset()

    def tearDown(self):
        Station.reset()

    def test_open_is_idempotent(self):
        a = Station.open({'config': None})
        b = Station.open({'config': None})
        self.assertIs(a, b)
        self.assertIs(a, Station.current())

    def test_open_conflict_is_an_error(self):
        Station.open({'config': None})
        with self.assertRaises(StationError) as caught:
            Station.open({'config': None, 'profile': 'prod'})
        self.assertEqual('station_open_conflict', caught.exception.code)

    def test_current_never_creates(self):
        self.assertIsNone(Station.current())

    def test_close_drops_the_ambient(self):
        st = Station.open({'config': None})
        st.close()
        self.assertIsNone(Station.current())

    def test_isolated_instance_stays_isolated(self):
        st = Station({'config': None})
        self.assertIsNone(Station.current())
        st.close()


class TestSecretBroker(unittest.TestCase):

    def test_miss_is_station_secret_no_value(self):
        broker = SecretBroker([{'kind': 'env'}])
        with self.assertRaises(StationError) as caught:
            broker.value('pets', 'no_such_secret_xyz.apikey')
        self.assertEqual('station_secret_no_value', caught.exception.code)

    def test_store_error_is_station_secret_error(self):
        class Angry:
            def lookup(self, name):
                raise RuntimeError('vault sealed')

            def describe(self):
                return 'angry'
        broker = SecretBroker([Angry()])
        with self.assertRaises(StationError) as caught:
            broker.value('pets', 'a.apikey')
        self.assertEqual('station_secret_error', caught.exception.code)
        self.assertIn('vault sealed', str(caught.exception))

    def test_scrub_has_no_length_floor(self):
        os.environ['T_APIKEY'] = 'ab'
        try:
            broker = SecretBroker([{'kind': 'env'}])
            self.assertEqual('ab', broker.value('t', 't.apikey'))
            # sekreto's own redact() keeps a 4-char floor; the station
            # scrub is absolute (design station.md 7 as revised).
            self.assertEqual('x [redacted] y', broker.scrub('x ab y'))
        finally:
            del os.environ['T_APIKEY']

    def test_hoist_overrides_resolution(self):
        broker = SecretBroker([{'kind': 'env'}])
        broker.hoist('pets', 'resident-key')
        self.assertEqual('resident-key', broker.value('pets', 'missing.apikey'))
        self.assertEqual('[redacted]', broker.scrub('resident-key'))


class TestEventBuffer(unittest.TestCase):

    def test_ring_drops_oldest(self):
        buffer = EventBuffer(3)
        for i in range(5):
            buffer.emit({'t': i, 'kind': 'station'})
        self.assertEqual([2, 3, 4], [e['t'] for e in buffer.events()])
        self.assertEqual({'buffered': 3, 'dropped': 2}, buffer.status())

    def test_tap_and_untap(self):
        buffer = EventBuffer()
        seen = []
        untap = buffer.tap(seen.append)
        buffer.emit({'t': 1, 'kind': 'station'})
        untap()
        buffer.emit({'t': 2, 'kind': 'station'})
        self.assertEqual(1, len(seen))

    def test_throwing_tap_never_fails_emit(self):
        buffer = EventBuffer()

        def bad(ev):
            raise RuntimeError('tap broke')
        buffer.tap(bad)
        buffer.emit({'t': 1, 'kind': 'station'})
        self.assertEqual(1, len(buffer.events()))


class TestBinding(unittest.TestCase):

    def setUp(self):
        Station.reset()
        os.environ['GNARLY_PETS_APIKEY'] = 'live-key-77'

    def tearDown(self):
        Station.reset()
        os.environ.pop('GNARLY_PETS_APIKEY', None)

    def test_placeholder_planted_and_injected(self):
        st = Station({'config': None})
        ctx, log = bind(st)

        self.assertEqual('[station:gnarly-pets]', ctx.options['apikey'])

        fetchdef = {'method': 'GET',
                    'headers': {'authorization': 'Bearer [station:gnarly-pets]'}}
        res, err = ctx.utility.fetcher(ctx, 'http://localhost:8903/api/pet', fetchdef)
        self.assertIsNone(err)
        self.assertEqual(200, res['status'])

        # Injection on the wire; copy-on-inject keeps the caller's
        # fetchdef (the object graph reachable from ctx/spec/ctrl)
        # holding only the placeholder (design station.md 5.3).
        self.assertEqual('Bearer live-key-77',
                         log[0]['fetchdef']['headers']['authorization'])
        self.assertEqual('Bearer [station:gnarly-pets]',
                         fetchdef['headers']['authorization'])

        http = [e for e in st.events() if 'http' == e['kind']]
        self.assertEqual(1, len(http))
        self.assertEqual(200, http[0]['http']['status'])
        st.close()

    def test_no_injection_into_mock_transports(self):
        st = Station({'config': None})
        ctx, log = bind(st, mode='test')
        fetchdef = {'method': 'GET',
                    'headers': {'authorization': 'Bearer [station:gnarly-pets]'}}
        ctx.utility.fetcher(ctx, 'http://localhost:8903/api/pet', fetchdef)
        self.assertEqual('Bearer [station:gnarly-pets]',
                         log[0]['fetchdef']['headers']['authorization'])
        st.close()

    def test_missing_secret_fails_on_the_op_path(self):
        del os.environ['GNARLY_PETS_APIKEY']
        st = Station({'config': None})
        ctx, log = bind(st)
        res, err = ctx.utility.fetcher(
            ctx, 'http://localhost:8903/api/pet', {'method': 'GET', 'headers': {}})
        self.assertIsNone(res)
        self.assertEqual('station_secret_no_value', err.code)
        self.assertEqual(0, len(log), 'nothing reached the wire')
        errs = [e for e in st.events() if 'error' == e['kind']]
        self.assertEqual(1, len(errs))
        self.assertEqual('station_secret_no_value', errs[0]['err']['code'])
        st.close()

    def test_wrap_order_guard_counts_by_name(self):
        st = Station({'config': None})
        client = FakeClient()
        utility = FakeUtility(base_fetcher([]))
        ctx = FakeCtx(client, utility, {'apikey': ''})

        # A stray inert feature FIRST (the py factory's BaseFeature
        # fallback shape), then the adapter appended after it: station is
        # not immediately outside the base transport, and the guard must
        # say so by name rather than trust indexes.
        class Stray:
            name = 'base'
        adapter = adapter_feature(st, None)
        client.features = [Stray(), adapter]
        with self.assertRaises(StationError) as caught:
            adapter.init(ctx, {'active': True})
        self.assertEqual('station_wrap_order', caught.exception.code)
        st.close()

    def test_second_arrival_is_inert_and_double_wrap_refused(self):
        st = Station({'config': None})
        ctx, _log = bind(st)

        # Second arrival on the SAME client: inert no-op (design
        # station.md 3.1), not an error, and no second wrap.
        binding = feature_binding(ctx, {'active': True, 'station': st})
        self.assertIsNone(binding)
        self.assertEqual(1, len(st.plugins()))

        # A genuinely second client of the same slug is refused.
        client2 = FakeClient()
        utility2 = FakeUtility(base_fetcher([]))
        ctx2 = FakeCtx(client2, utility2, {'apikey': ''})
        adapter2 = adapter_feature(st, None)
        client2.features.append(adapter2)
        with self.assertRaises(StationError) as caught:
            adapter2.init(ctx2, {'active': True})
        self.assertEqual('station_bound_twice', caught.exception.code)
        st.close()

    def test_hosts_policy_denies_off_list_egress(self):
        st = Station({'config': {
            'station': 1,
            'profiles': {'default': {'sdk': {
                'gnarly-pets': {'policy': {'hosts': ['api.other.example']}},
            }}},
        }})
        ctx, log = bind(st)
        res, err = ctx.utility.fetcher(
            ctx, 'http://localhost:8903/api/pet', {'method': 'GET', 'headers': {}})
        self.assertEqual('station_host_allow', err.code)
        self.assertEqual(0, len(log))
        st.close()

    def test_hosts_policy_sends_manual_redirects(self):
        st = Station({'config': {
            'station': 1,
            'profiles': {'default': {'sdk': {
                'gnarly-pets': {'policy': {'hosts': ['localhost']}},
            }}},
        }})
        ctx, log = bind(st)
        ctx.utility.fetcher(ctx, 'http://localhost:8903/api/pet',
                            {'method': 'GET', 'headers': {}})
        self.assertEqual('manual', log[0]['fetchdef']['redirect'])
        st.close()

    def test_adopt_hoists_a_resident_credential(self):
        st = Station({'config': None})
        ctx, log = bind(st, options={'apikey': 'resident-9'})
        self.assertEqual('[station:gnarly-pets]', ctx.options['apikey'])
        warns = [e for e in st.events() if 'station' == e['kind'] and
                 'hoisted' in str((e.get('meta') or {}).get('warn', ''))]
        self.assertEqual(1, len(warns))

        # The hoisted value is what gets injected, and the scrub hides it.
        fetchdef = {'method': 'GET',
                    'headers': {'authorization': '[station:gnarly-pets]'}}
        ctx.utility.fetcher(ctx, 'http://localhost:8903/api/pet', fetchdef)
        self.assertEqual('resident-9',
                         log[0]['fetchdef']['headers']['authorization'])
        self.assertEqual('[redacted]', st.redact('resident-9'))
        st.close()

    def test_require_proxy_fails_operations_not_construction(self):
        st = Station({'config': None, 'proxy': 'require'})
        ctx, log = bind(st)
        res, err = ctx.utility.fetcher(
            ctx, 'http://localhost:8903/api/pet', {'method': 'GET', 'headers': {}})
        self.assertEqual('station_no_proxy', err.code)
        self.assertEqual(0, len(log))
        st.close()

    def test_no_station_open_is_an_inert_noop(self):
        client = FakeClient()
        utility = FakeUtility(base_fetcher([]))
        ctx = FakeCtx(client, utility, {'apikey': ''})
        binding = feature_binding(ctx, {'active': True})
        self.assertIsNone(binding)

    def test_auth_inactive_still_observes(self):
        config = {'main': {'name': 'Solardemo', 'slug': 'solardemo',
                           'version': '1.0.0', 'target': 'py'},
                  'feature': {}, 'entity': {},
                  'options': {'base': 'http://localhost:1', 'entity': {}}}
        st = Station({'config': None})
        ctx, log = bind(st, options={}, config=config)
        self.assertEqual('none', st.plugins()[0]['rung'])
        self.assertNotIn('apikey', ctx.options)
        ctx.utility.fetcher(ctx, 'http://localhost:1/api/x',
                            {'method': 'GET', 'headers': {}})
        self.assertEqual(1, len([e for e in st.events() if 'http' == e['kind']]))
        st.close()


if __name__ == '__main__':
    unittest.main()
