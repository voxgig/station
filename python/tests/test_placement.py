# RUN: python3 -m unittest discover -s tests
#
# A port of typescript/test/placement.test.ts, which is canonical.

import os
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

from voxgig_station import Station, adapter_anchor, provide, reset_factories  # noqa: E402


def generated_sdk(slug, statuses):
    """What an SDK generated without the station feature does when it is
    constructed: make_options' feature order, the constructor's loops,
    feature_add's anchors and feature_init, as sdkgen's py templates
    write them. `statuses` scripts the wire, one status per attempt."""
    config = {
        'main': {'name': slug, 'slug': slug, 'version': '1.0.0', 'target': 'py'},
        'feature': {'cache': {}, 'retry': {}, 'test': {}},
        'options': {'base': 'http://api.test', 'auth': {'prefix': ''},
                    'entity': {}},
        'entity': {},
    }
    sent = []
    calls = []

    def wire(_ctx, url, _fetchdef):
        sent.append(url)
        status = statuses[len(sent) - 1] if len(sent) <= len(statuses) else 200
        return {'status': status, 'headers': {}}, None

    class Feature:
        def __init__(self, name):
            self.name = name

        def init(self, ctx, _fopts):
            inner = ctx.utility.fetcher
            if 'test' == self.name:
                def mock(_c, _url, _def):
                    return {'status': 200, 'headers': {}}, None
                ctx.utility.fetcher = mock
            elif 'retry' == self.name:
                def retry(c, url, fdef):
                    calls.append('retry')
                    res, err = inner(c, url, fdef)
                    for _ in range(2):
                        if err is not None or 503 != res['status']:
                            break
                        res, err = inner(c, url, fdef)
                    return res, err
                ctx.utility.fetcher = retry
            else:
                name = self.name

                def passthrough(c, url, fdef):
                    calls.append(name)
                    return inner(c, url, fdef)
                ctx.utility.fetcher = passthrough

    def featureorder(fmap):
        names = sorted(fmap.keys())
        if 'test' in names:
            names = ['test'] + [n for n in names if n != 'test']
        if 'station' in names:
            names.remove('station')
            at = names.index('test') + 1 if 'test' in names else 0
            names.insert(at, 'station')
        return names

    def feature_add(client, f):
        fopts = getattr(f, '_options', None) or {}
        for i, ef in enumerate(client.features):
            if fopts.get('__before__') == ef.name:
                client.features.insert(i, f)
                return
            if fopts.get('__after__') == ef.name:
                client.features.insert(i + 1, f)
                return
            if fopts.get('__replace__') == ef.name:
                client.features[i] = f
                return
        client.features.append(f)

    class Utility:
        def __init__(self):
            self.fetcher = wire

    class Ctx:
        def __init__(self, client, utility, options):
            self.client = client
            self.utility = utility
            self.options = options
            self.config = config
            self.op = None
            self.entity = None
            self.result = None

    class Op:
        entity = 'todo'
        name = 'list'

    class Result:
        def __init__(self, status):
            self.ok = 200 == status
            self.err = None

    class SDK:
        def __init__(self, options):
            self.options = dict(options or {})
            # A list is init order as given; a dict is ordered as above.
            given = self.options.get('feature')
            listed = given if isinstance(given, list) else None
            fmap = given or {} if listed is None else {
                f['name']: {k: v for k, v in f.items() if 'name' != k} for f in listed}
            self.mode = 'test' if (fmap.get('test') or {}).get('active') is True else 'live'
            self.features = []
            self.utility = Utility()
            self.ctx = Ctx(self, self.utility, self.options)

            extend = self.options.get('extend') or []
            order = featureorder(fmap) if listed is None else [f['name'] for f in listed]
            for fname in order:
                if (fmap.get(fname) or {}).get('active') is True:
                    if fname not in config['feature'] and \
                            any(fname == getattr(f, 'name', None) for f in extend):
                        continue
                    feature_add(self, Feature(fname))
            for f in extend:
                feature_add(self, f)
            for f in self.features:
                fopts = fmap.get(f.name) or {}
                if fopts.get('active') is True:
                    f.init(self.ctx, fopts)

        def list(self):
            ctx = Ctx(self, self.utility, self.options)
            ctx.op = Op()
            for f in self.features:
                hook = getattr(f, 'PrePoint', None)
                if hook:
                    hook(ctx)
            res, err = self.utility.fetcher(ctx, 'http://api.test/todo',
                                            {'method': 'GET', 'headers': {}})
            ctx.result = Result(res['status'] if err is None else 0)
            for f in self.features:
                hook = getattr(f, 'PreDone', None)
                if hook:
                    hook(ctx)
            return res

    SDK.config = config
    SDK.calls = calls
    return SDK, config, sent


def names(client):
    return [f.name for f in client.features]


def wire_events(station):
    return [[e['kind'], (e.get('http') or {}).get('status')
             if 'http' == e['kind'] else e['op']['outcome']]
            for e in station.events() if e['kind'] in ('http', 'op')]


class TestAdapterAnchor(unittest.TestCase):

    def test_after_test_when_active_else_before_the_first_by_name(self):
        self.assertEqual({}, adapter_anchor(None))
        self.assertEqual({}, adapter_anchor({}))
        self.assertEqual({}, adapter_anchor({'station': {'active': True}}))
        self.assertEqual({'__before__': 'retry'},
                         adapter_anchor({'retry': {'active': True}}))
        self.assertEqual({'__before__': 'cache'},
                         adapter_anchor({'retry': {'active': True},
                                         'cache': {'active': True}}))
        self.assertEqual({'__before__': 'retry'},
                         adapter_anchor({'cache': {'active': False},
                                         'retry': {'active': True}}))
        self.assertEqual({'__before__': 'timeout'},
                         adapter_anchor({'station': {'active': True},
                                         'timeout': {'active': True}}))
        self.assertEqual({'__after__': 'test'},
                         adapter_anchor({'test': {'active': True},
                                         'retry': {'active': True}}))
        self.assertEqual({'__before__': 'retry'},
                         adapter_anchor({'test': {'active': False},
                                         'retry': {'active': True}}))
        # sdkgen's ordered list form: list order is init order.
        self.assertEqual({'__before__': 'retry'},
                         adapter_anchor([{'name': 'retry', 'active': True}]))
        self.assertEqual({'__before__': 'retry'},
                         adapter_anchor([{'name': 'retry', 'active': True},
                                         {'name': 'cache', 'active': True}]))
        self.assertEqual({'__after__': 'test'},
                         adapter_anchor([{'name': 'retry', 'active': True},
                                         {'name': 'test', 'active': True}]))
        self.assertEqual({}, adapter_anchor([{'name': 'station', 'active': True},
                                             {'name': 'retry'}]))


class TestCarriedAdapterPlacement(unittest.TestCase):

    def setUp(self):
        Station.reset()
        reset_factories()
        os.environ['TASKPAD_APIKEY'] = 'taskpad-key'

    def tearDown(self):
        Station.reset()
        reset_factories()
        os.environ.pop('TASKPAD_APIKEY', None)

    def test_live_with_retry_station_is_the_base_wrap(self):
        SDK, _config, sent = generated_sdk('taskpad', [503, 200])
        st = Station({'config': None})
        client = st.connect(SDK, {'feature': {'retry': {'active': True}}})

        self.assertEqual(['station', 'retry'], names(client))
        client.list()

        self.assertEqual(2, len(sent))
        self.assertEqual([['http', 503], ['http', 200], ['op', 'ok']],
                         wire_events(st))
        st.close()

    def test_live_with_two_features_before_the_first_by_name(self):
        SDK, _config, _sent = generated_sdk('taskpad', [])
        st = Station({'config': None})
        client = st.adopt(SDK, {'feature': {'retry': {'active': True},
                                            'cache': {'active': True}}})
        self.assertEqual(['station', 'cache', 'retry'], names(client))
        st.close()

    def test_test_mode_station_sits_on_the_mock_transport(self):
        SDK, _config, _sent = generated_sdk('taskpad', [])
        st = Station({'config': None})
        client = st.connect(SDK, {'feature': {'test': {'active': True},
                                              'retry': {'active': True}}})
        self.assertEqual(['test', 'station', 'retry'], names(client))
        st.close()

    def test_no_other_feature_station_alone(self):
        SDK, _config, _sent = generated_sdk('taskpad', [])
        st = Station({'config': None})
        self.assertEqual(['station'], names(st.connect(SDK)))
        st.close()

    def test_the_declarative_path_places_it_the_same_way(self):
        SDK, config, sent = generated_sdk('taskpad', [503, 200])
        provide('taskpad', {'construct': SDK, 'config': config})
        st = Station({'config': {
            'station': 1,
            'profiles': {'default': {'sdk': {
                'taskpad': {'feature': {'retry': {}}}}}},
        }})
        client = st.sdk('taskpad')

        self.assertEqual(['station', 'retry'], names(client))
        client.list()
        self.assertEqual(2, len(sent))
        self.assertEqual([['http', 503], ['http', 200], ['op', 'ok']],
                         wire_events(st))
        st.close()

    def test_a_declared_order_the_alphabet_disagrees_with_reaches_the_wire(self):
        SDK, config, _sent = generated_sdk('taskpad', [200])
        provide('taskpad', {'construct': SDK, 'config': config})
        st = Station({'config': {
            'station': 1,
            'profiles': {'default': {'sdk': {'taskpad': {'feature': {
                'retry': {}, 'cache': {'order': {'before': 'retry'}}}}}}},
        }})
        client = st.sdk('taskpad')

        self.assertEqual(['station', 'retry', 'cache'], names(client))
        client.list()
        self.assertEqual(['cache', 'retry'], SDK.calls, 'cache wraps retry')
        st.close()


if __name__ == '__main__':
    unittest.main()
