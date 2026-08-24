# RUN: python3 -m unittest discover -s tests
#
# Focused unit tests for the py port: the ambient contract, the secret
# broker's miss-vs-error distinction and exact-value scrub, the event
# ring, and the binding path (wrap position, placeholder planting,
# copy-on-inject, mock non-injection, hosts policy) against a faithful
# miniature of the py SDK's seams. Integration against a REAL generated
# SDK lives in the consumer validation flow, not here.

import json
import os
import shutil
import sys
import tempfile
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
    BLOCK_DEFAULTS,
    MERGE_SENSITIVE,
    PROFILE_DEFAULTS,
    Station,
    StationError,
    adapter_feature,
    camelify,
    check_features,
    check_package,
    config_shape,
    factory_for,
    factory_from_module,
    feature_binding,
    load_sync,
    normalize_config,
    normalize_descriptor,
    placeholder_for,
    provide,
    provided,
    reset_factories,
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


# --- the declarative front door (design station.md 6) ---

# A generated py SDK in miniature: the constructor takes one options
# map, builds its features from `extend`, and inits them against a ctx
# carrying client/utility/options/config. Enough of the real seam for
# the binding to run, and no more (the real thing is exercised in the
# consumer validation flow).
PAD_CONFIG = {
    'main': {'name': 'Pad', 'slug': 'pad', 'version': '2.0.0', 'target': 'py'},
    'feature': {
        'retry': {'options': {'retries': 1, 'wait': 100}},
        'ratelimit': {'options': {'rate': 1, 'burst': 1}},
        'test': {},
    },
    'options': {'base': 'http://localhost:9', 'auth': {'prefix': 'Bearer'},
                'entity': {}},
    'entity': {},
}


class FakeSDK:
    def __init__(self, options):
        self.options = dict(options)
        self.mode = 'live'
        self.features = []
        self.log = []
        self.utility = FakeUtility(base_fetcher(self.log))
        ctx = FakeCtx(self, self.utility, self.options, self.config)
        fopts = (self.options.get('feature') or {}).get('station') or {}
        for f in self.options.get('extend') or []:
            self.features.append(f)
            f.init(ctx, fopts)

    config = PAD_CONFIG


def pad_factory():
    return {'construct': FakeSDK, 'config': PAD_CONFIG}


def cfg(sdk=None, api=None, feature=None, profiles=None):
    """A station.json in code."""
    if profiles is None:
        default = {}
        if sdk is not None:
            default['sdk'] = sdk
        if api is not None:
            default['api'] = api
        if feature is not None:
            default['feature'] = feature
        profiles = {'default': default}
    return {'station': 1, 'profiles': profiles}


class TestFactoryTable(unittest.TestCase):

    def setUp(self):
        reset_factories()

    def tearDown(self):
        reset_factories()

    def test_provide_normalizes_the_descriptor_at_provide_time(self):
        entry = provide('pad', pad_factory())
        self.assertEqual('pad', entry['descriptor']['slug'])
        self.assertEqual(['pad'], provided())
        # The feature schema is there BEFORE anything is constructed -
        # which is what lets check() validate without a client.
        retry = [f for f in entry['descriptor']['features']
                 if 'retry' == f['name']][0]
        self.assertEqual({'retries': 1, 'wait': 100}, retry['options'])

    def test_the_same_pair_twice_is_a_noop(self):
        factory = pad_factory()
        first = provide('pad', factory)
        self.assertIs(first, provide('pad', factory))
        self.assertIs(first, provide('pad', dict(factory)))

    def test_a_different_factory_is_a_conflict(self):
        provide('pad', pad_factory())
        with self.assertRaises(StationError) as caught:
            provide('pad', {'construct': lambda o: None, 'config': PAD_CONFIG})
        self.assertEqual('station_factory_conflict', caught.exception.code)

    def test_station_provide_fills_the_one_table(self):
        Station.provide('pad', pad_factory())
        self.assertIsNotNone(factory_for('pad'))


class TestLoader(unittest.TestCase):

    def test_only_module_names_are_accepted(self):
        self.assertEqual('acme_sdk', check_package('pad', 'acme_sdk'))
        for bad in ('', '.', './pkg', '/abs/pkg', '~/pkg',
                    'pkg/../../escape', 'https://x/y', 'pkg\\win'):
            with self.assertRaises(StationError, msg=bad) as caught:
                check_package('pad', bad)
            self.assertEqual('station_sdk_load', caught.exception.code)

    def test_camelify(self):
        self.assertEqual('StripeEu', camelify('stripe-eu'))
        self.assertEqual('VoxgigSolardemo', camelify('voxgig_solardemo'))

    def test_factory_from_module_finds_the_fixed_alias_first(self):
        class Alias(FakeSDK):
            pass

        class Derived(FakeSDK):
            pass

        class Mod:
            SDK = Alias
            PadSDK = Derived
            config = PAD_CONFIG
        factory = factory_from_module('pad', Mod)
        # The fixed alias is the same identifier in every generated
        # package; the derived name is the SECOND attempt.
        self.assertIsInstance(factory['construct']({}), Alias)
        self.assertIs(PAD_CONFIG, factory['config'])
        # ...and an explicit `export` is the third and wins over both.
        self.assertIsInstance(
            factory_from_module('pad', Mod, 'PadSDK')['construct']({}), Derived)

    def test_factory_from_module_falls_back_to_the_derived_name(self):
        class Derived(FakeSDK):
            pass

        class Mod:
            PadSDK = Derived
            CONFIG = PAD_CONFIG
        factory = factory_from_module('pad', Mod)
        self.assertIsInstance(factory['construct']({}), Derived)
        self.assertIs(PAD_CONFIG, factory['config'])

    def test_no_constructor_names_what_was_tried(self):
        class Mod:
            config = PAD_CONFIG
        with self.assertRaises(StationError) as caught:
            factory_from_module('pad', Mod, 'Nope')
        self.assertEqual('station_sdk_load', caught.exception.code)
        self.assertIn('tried [Nope, SDK, PadSDK]', str(caught.exception))

    def test_a_constructor_without_a_config_is_refused(self):
        class Mod:
            SDK = FakeSDK
        with self.assertRaises(StationError) as caught:
            factory_from_module('pad', Mod)
        self.assertEqual('station_sdk_load', caught.exception.code)
        self.assertIn('`config` singleton', str(caught.exception))


# A package on sys.path, written at test time: the loader's one job is
# to import a module BY NAME, so proving it needs a real importable
# module and nothing else.
_RETRO_SDK = """
CONFIG = {'main': {'name': 'Pad', 'slug': 'pad', 'version': '1.0.0',
                   'target': 'py'},
          'feature': {}, 'options': {}, 'entity': {}}


class SDK:
    # A pre-station SDK in miniature: it consumes no `extend`, which is
    # exactly the retrofit case factory_from_module exists for.
    def __init__(self, options):
        self.options = options


config = CONFIG
"""

_SELF_SDK = """
from voxgig_station import provide

CONFIG = {'main': {'name': 'Pad', 'slug': 'pad', 'version': '9.9.9',
                   'target': 'py'},
          'feature': {}, 'options': {}, 'entity': {}}


class SDK:
    def __init__(self, options):
        self.options = options


provide('pad', {'construct': SDK, 'config': CONFIG})
"""


class TestLoaderImport(unittest.TestCase):
    """py IS A LOADER LANGUAGE (design 6.3): a module can be imported by
    name at runtime, so `api.<slug>.package` closes the loop."""

    def setUp(self):
        Station.reset()
        reset_factories()
        self._dir = tempfile.mkdtemp()
        sys.path.insert(0, self._dir)
        for name, src in (('pad_retro_sdk', _RETRO_SDK),
                          ('pad_self_sdk', _SELF_SDK)):
            with open(os.path.join(self._dir, name + '.py'), 'w') as handle:
                handle.write(src)

    def tearDown(self):
        Station.reset()
        reset_factories()
        if self._dir in sys.path:
            sys.path.remove(self._dir)
        for name in ('pad_retro_sdk', 'pad_self_sdk'):
            sys.modules.pop(name, None)
        shutil.rmtree(self._dir, ignore_errors=True)

    def test_a_module_that_self_registers_needs_no_exports(self):
        self.assertTrue(load_sync('pad', 'pad_self_sdk'))
        # Path 1: the factory is the one the module registered itself.
        self.assertEqual('9.9.9', factory_for('pad')['descriptor']['version'])

    def test_a_retrofit_module_is_read_through_its_exports(self):
        self.assertTrue(load_sync('pad', 'pad_retro_sdk'))
        self.assertEqual('1.0.0', factory_for('pad')['descriptor']['version'])
        # Already registered: a second call is a lookup, not an import.
        self.assertTrue(load_sync('pad', 'pad_retro_sdk'))

    def test_an_unimportable_package_says_so(self):
        with self.assertRaises(StationError) as caught:
            load_sync('pad', 'no_such_pad_sdk')
        self.assertEqual('station_sdk_load', caught.exception.code)
        self.assertIn('could not be imported', str(caught.exception))

    def test_the_declarative_path_loads_a_configured_package(self):
        st = Station({'config': cfg(
            api={'pad': {'package': 'pad_retro_sdk'}},
            sdk={'pad': {}})})
        client = st.sdk('pad')
        # The instance name reaches the constructor the same way it does
        # on the imperative path, so registration has one spelling.
        self.assertEqual(
            'pad', client.options['feature']['station']['instance'])
        st.close()

    def test_load_preloads_the_declared_packages(self):
        st = Station({'config': cfg(sdk={
            'pad': {'package': 'pad_self_sdk'},
            'pad$off': {'active': False, 'secret': 'pad_off.apikey',
                        'package': 'no_such_pad_sdk'},
        })})
        # Inactive instances are skipped, so the unimportable one is not
        # reached: warm/load reach for what is meant to run.
        st.load()
        self.assertEqual(['pad'], provided())
        st.close()


class TestDeclarative(unittest.TestCase):

    def setUp(self):
        Station.reset()
        reset_factories()
        provide('pad', pad_factory())
        os.environ['PAD_APIKEY'] = 'pad-key'

    def tearDown(self):
        Station.reset()
        reset_factories()
        os.environ.pop('PAD_APIKEY', None)
        os.environ.pop('PAD_PROD_APIKEY', None)

    def test_sdk_constructs_once_and_caches(self):
        st = Station({'config': cfg(sdk={'pad': {}})})
        first = st.sdk('pad')
        self.assertIs(first, st.sdk('pad'))
        self.assertEqual(['pad'], [p['name'] for p in st.plugins()])
        self.assertEqual('pad', st.plugins()[0]['api'])
        self.assertEqual('pad.apikey', st.plugins()[0]['secretname'])
        st.close()

    def test_an_undeclared_name_names_what_is_declared(self):
        st = Station({'config': cfg(sdk={'pad': {}, 'pad$eu': {}})})
        with self.assertRaises(StationError) as caught:
            st.sdk('pad$nope')
        self.assertEqual('station_no_instance', caught.exception.code)
        self.assertIn('declared: [pad, pad$eu]', str(caught.exception))
        st.close()

    def test_inactive_is_declared_but_barred(self):
        st = Station({'config': cfg(sdk={'pad': {'active': False}})})
        with self.assertRaises(StationError) as caught:
            st.sdk('pad')
        self.assertEqual('station_instance_inactive', caught.exception.code)
        # ...and still visible in instances().
        row = st.instances()[0]
        self.assertEqual(False, row['active'])
        self.assertEqual(False, row['live'])
        st.close()

    def test_no_factory_names_the_remedies(self):
        reset_factories()
        st = Station({'config': cfg(sdk={'pad': {}})})
        with self.assertRaises(StationError) as caught:
            st.sdk('pad')
        self.assertEqual('station_no_factory', caught.exception.code)
        self.assertIn('Station.provide("pad", ...)', str(caught.exception))
        st.close()

    def test_create_auto_tags_and_the_tag_stands_for_the_declaration(self):
        st = Station({'config': cfg(sdk={
            'pad$prod': {'policy': {'hosts': ['api.pad.example']},
                         'secret': 'pad_prod.apikey'}})})
        one = st.create('pad$prod')
        two = st.create('pad$prod')
        self.assertIsNot(one, two)
        self.assertEqual(['pad$1', 'pad$2'],
                         sorted(p['name'] for p in st.plugins()))

        # THE ALIAS IS RECORDED, NOT THE FIELDS: the auto-tagged client
        # keeps the declared instance's whole block, allowlist included.
        self.assertEqual('pad$prod', st.declared_ref('pad$1'))
        self.assertEqual(['api.pad.example'],
                         st.block_for('pad$1')['policy']['hosts'])
        # ...and its secret follows the DECLARED instance, so every
        # per-request client shares one broker cache entry.
        self.assertEqual('pad_prod.apikey',
                         [p for p in st.plugins()
                          if 'pad$1' == p['name']][0]['secretname'])
        st.close()

    def test_auto_tag_skips_a_declared_tag(self):
        st = Station({'config': cfg(sdk={'pad$prod': {}, 'pad$1': {}})})
        self.assertEqual('pad$2', st.auto_tag('pad$prod'))
        st.close()

    def test_two_instances_of_one_api_get_distinct_placeholders(self):
        st = Station({'config': cfg(sdk={
            'pad': {}, 'pad$eu': {'secret': 'pad_eu.apikey'}})})
        st.sdk('pad')
        st.sdk('pad$eu')
        self.assertEqual('[station:pad]', st.sdk('pad').options['apikey'])
        self.assertEqual('[station:pad$eu]',
                         st.sdk('pad$eu').options['apikey'])
        st.close()

    def test_the_composed_feature_map_is_ordered_and_station_free(self):
        st = Station({'config': cfg(sdk={'pad': {'feature': {
            'retry': {'retries': 3},
            'ratelimit': {'order': {'after': 'retry'}},
        }}})})
        client = st.sdk('pad')
        fmap = client.options['feature']
        # `station` is composed by options(), after the user merge, so
        # it is never taken from the config's own map.
        self.assertEqual(['retry', 'ratelimit', 'station'], list(fmap.keys()))
        self.assertEqual({'active': True, 'retries': 3}, fmap['retry'])
        # RESERVED_KEYS never reach the SDK's option map.
        self.assertNotIn('order', fmap['ratelimit'])
        st.close()

    def test_an_unknown_feature_option_fails_the_build(self):
        st = Station({'config': cfg(sdk={'pad': {'feature': {
            'retry': {'retires': 5}}}})})
        with self.assertRaises(StationError) as caught:
            st.sdk('pad')
        self.assertEqual('station_feature_option', caught.exception.code)
        self.assertIn('declares no option "retires"', str(caught.exception))
        st.close()

    def test_an_unknown_feature_fails_the_build(self):
        st = Station({'config': cfg(sdk={'pad': {'feature': {
            'nosuch': {'x': 1}}}})})
        with self.assertRaises(StationError) as caught:
            st.sdk('pad')
        self.assertEqual('station_feature_unknown', caught.exception.code)
        st.close()

    def test_features_of_carries_provenance(self):
        st = Station({'profile': 'prod', 'config': cfg(profiles={
            'default': {
                'feature': {'retry': {'retries': 1}},
                'sdk': {'pad': {'feature': {'retry': {'wait': 5}}}},
            },
            'prod': {'feature': {'retry': {'retries': 9}}},
        })})
        got = st.features_of('pad')
        # PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, per key. NO
        # `active` IS SYNTHESIZED: features_of reads the RAW config, and
        # a tuning-only mention must not switch a feature on.
        self.assertEqual({'retries': 9, 'wait': 5}, got['merged']['retry'])
        self.assertEqual('prod.feature', got['from']['retry']['retries'])
        self.assertEqual('default.sdk', got['from']['retry']['wait'])
        # The implicit station row is for ORDERING ONLY.
        self.assertIn('station', got['ordered'])
        self.assertNotIn('station', got['merged'])
        st.close()

    def test_policy_budget_composes_into_ratelimit(self):
        st = Station({'config': cfg(sdk={'pad': {
            'policy': {'budget': {'rps': 5, 'concurrency': 2}},
            'feature': {'ratelimit': {'rate': 99}},
        }})})
        got = st.features_of('pad')
        # POLICY WINS on the keys it sets; other tuning survives beside it.
        self.assertEqual({'active': True, 'rate': 5, 'burst': 2},
                         got['merged']['ratelimit'])
        self.assertEqual('policy.budget', got['from']['ratelimit']['rate'])
        st.close()

    def test_features_filters_rows_and_narrows_them(self):
        st = Station({'config': cfg(sdk={
            'pad': {'feature': {'retry': {'retries': 2}}},
            'pad$eu': {'secret': 'pad_eu.apikey'},
        })})
        rows = st.features({'feature': 'retry'})
        self.assertEqual(['pad'], [r['instance'] for r in rows])
        self.assertEqual(['retry'], list(rows[0]['merged'].keys()))
        self.assertEqual(['retry'], rows[0]['ordered'])
        # The string form is the loose instance-or-api shorthand.
        self.assertEqual(['pad', 'pad$eu'],
                         [r['instance'] for r in st.features('pad')])
        st.close()

    def test_check_reports_ok_and_failed(self):
        st = Station({'config': cfg(sdk={
            'pad': {},
            'pad$bad': {'secret': 'pad_bad.apikey',
                        'feature': {'retry': {'retires': 1}}},
            'pad$off': {'active': False, 'secret': 'pad_off.apikey'},
        })})
        got = st.check()
        self.assertEqual(['pad'], got['ok'])
        self.assertEqual(['pad$bad'], [f['name'] for f in got['failed']])
        self.assertEqual('station_feature_option', got['failed'][0]['code'])
        st.close()

    def test_warm_dedupes_by_secret_name_and_misses_the_unknown(self):
        os.environ['PAD_APIKEY'] = 'pad-key'
        st = Station({'config': cfg(
            api={'pad': {'secret': 'pad.apikey'}},
            sdk={'pad': {}, 'pad$eu': {}})})

        # ONE RESOLUTION PER DISTINCT SECRET NAME: two instances sharing
        # one api-level `secret` must cost one round-trip, which is the
        # thing the method exists for.
        asked = []
        inner = st._broker.value

        def counted(instance, secretname):
            asked.append(secretname)
            return inner(instance, secretname)
        st._broker.value = counted

        got = st.warm()
        self.assertEqual(['pad', 'pad$eu'], got['warmed'])
        self.assertEqual([], got['missed'])
        self.assertEqual(['pad.apikey'], asked)

        # A name nobody declared or registered is a MISS, never a lookup.
        del asked[:]
        self.assertEqual({'warmed': [], 'missed': ['pad$typo']},
                         st.warm(['pad$typo']))
        self.assertEqual([], asked)
        st.close()

    def test_an_ordering_may_not_move_the_station_pin(self):
        # The implicit `station` row is what makes this rejectable: with
        # no row there is nothing to pin and the constraint would be
        # treated as vacuous (6.6).
        st = Station({'config': cfg(sdk={'pad': {'feature': {
            'retry': {'order': {'after': 'station'}}}}})})
        with self.assertRaises(StationError) as caught:
            st.features_of('pad')
        self.assertEqual('station_feature_order', caught.exception.code)
        self.assertIn('pinned innermost', str(caught.exception))
        st.close()

    def test_a_feature_cycle_is_refused(self):
        st = Station({'config': cfg(sdk={'pad': {'feature': {
            'retry': {'order': {'after': 'ratelimit'}},
            'ratelimit': {'order': {'after': 'retry'}},
        }}})})
        with self.assertRaises(StationError) as caught:
            st.sdk('pad')
        self.assertEqual('station_feature_order', caught.exception.code)
        self.assertIn('form a cycle among [ratelimit, retry]',
                      str(caught.exception))
        st.close()

    def test_instances_is_every_declared_one(self):
        st = Station({'config': cfg(sdk={'pad$eu': {}, 'pad': {}})})
        st.sdk('pad')
        rows = st.instances()
        self.assertEqual(['pad', 'pad$eu'], [r['name'] for r in rows])
        self.assertEqual([True, False], [r['live'] for r in rows])
        self.assertEqual(['R1', 'none'], [r['rung'] for r in rows])
        st.close()

    def test_a_malformed_config_fails_open_with_every_error(self):
        with self.assertRaises(StationError) as caught:
            Station({'config': cfg(sdk={'a': {'bass': 1}, 'b': {'tuba': 2}})})
        self.assertEqual('station_config_invalid', caught.exception.code)
        self.assertIn('sdk.a: bass', str(caught.exception))
        self.assertIn('sdk.b: tuba', str(caught.exception))

    def test_repo_scoped_reads_the_explicit_option_first(self):
        # An in-code config is repo-scoped by construction...
        self.assertTrue(Station({'config': cfg()}).repo_scoped)
        # ...and the explicit option still wins, or the rule is
        # untestable for every caller that passes a config in code.
        st = Station({'config': cfg(sdk={'pad': {'package': 'nope_pkg'}}),
                      'repo_scoped': False})
        self.assertFalse(st.repo_scoped)
        self.assertIsNone(
            st.loader_package('pad', st.instances()[0]['block']))
        warns = [e for e in st.events()
                 if 'ignoring `package`' in str((e.get('meta') or {}).get('warn', ''))]
        self.assertEqual(1, len(warns))
        st.close()

    def test_load_false_leaves_the_loader_inert(self):
        st = Station({'config': cfg(sdk={'pad': {'package': 'nope_pkg'}}),
                      'load': False})
        self.assertIsNone(
            st.loader_package('pad', st.instances()[0]['block']))
        st.load()
        st.close()


class TestFeatureChecker(unittest.TestCase):
    """design 8.5, derived from the descriptor and never hand-written."""

    def descriptor(self):
        return normalize_descriptor(PAD_CONFIG, None)[0]

    def test_scalars_are_kind_checked(self):
        faults = check_features({'retry': {'retries': 'lots'}},
                                self.descriptor())
        self.assertEqual(1, len(faults))
        self.assertEqual('station_feature_option', faults[0]['code'])
        self.assertIn('expects number, but found string', faults[0]['message'])

    def test_reserved_keys_are_not_options(self):
        self.assertEqual([], check_features(
            {'retry': {'active': True, 'order': {'band': 3}, 'retries': 2}},
            self.descriptor()))

    def test_a_non_map_entry_is_skipped(self):
        self.assertEqual([], check_features({'retry': False},
                                            self.descriptor()))

    def test_faults_collect_rather_than_throw(self):
        faults = check_features({'zzz': {}, 'aaa': {}}, self.descriptor())
        # Sorted, so the report reads the same in every port.
        self.assertEqual(['aaa', 'zzz'], [f['feature'] for f in faults])


class TestConfigShape(unittest.TestCase):
    """Guards on the config grammar as DATA (design 4.3, 10.1). These
    assert properties of the shape file itself, not of any config that
    runs through it - the sdkgen discipline for data that must be
    duplicated."""

    def test_normalize_never_mutates_the_input(self):
        raw = {'station': 1, 'profiles': {'default': {
            'sdk': {'pad': {'feature': {'retry': {'retries': 3}}}}}}}
        before = json.dumps(raw, sort_keys=True)
        out = normalize_config(raw)
        self.assertEqual(before, json.dumps(raw, sort_keys=True))
        # ...and the copy really did materialize the defaults.
        self.assertEqual(True, out['profiles']['default']['sdk']['pad']['active'])
        self.assertEqual(True, out['profiles']['default']['sdk']['pad']
                         ['feature']['retry']['active'])

    def test_a_non_map_is_returned_untouched(self):
        # validate rejects it with a message that names the path; the
        # normalizer never coerces and never drops.
        self.assertEqual([1], normalize_config([1]))

    def test_every_call_gets_a_fresh_copy(self):
        # struct's validate CONSUMES the spec it walks, so two configs
        # validated against one parsed constant would not be validated
        # against the same grammar.
        first = config_shape()
        first['profiles'] = 'eaten'
        self.assertNotEqual('eaten', config_shape()['profiles'])

    def test_the_two_block_specs_are_identical(self):
        profile = config_shape()['profiles']['`$CHILD`']
        self.assertEqual(profile['api']['`$CHILD`'], profile['sdk']['`$CHILD`'],
                         'the api and sdk block specs are one concept '
                         'written twice as data; they must not drift')

    def test_exactly_one_block_default_is_merge_sensitive(self):
        self.assertEqual(['active'], MERGE_SENSITIVE)
        for k in MERGE_SENSITIVE:
            self.assertIn(k, BLOCK_DEFAULTS,
                          k + ' is merge-sensitive but has no default')
        # Containers are safe early; a scalar is not. `active` is the
        # only scalar in either table, which is WHY it is the only entry
        # above.
        for label, table in (('profile', PROFILE_DEFAULTS),
                             ('block', BLOCK_DEFAULTS)):
            for k, mk in table.items():
                v = mk()
                container = isinstance(v, (dict, list))
                self.assertTrue(
                    container or k in MERGE_SENSITIVE,
                    label + ' default `' + k + '` is a scalar but is not '
                    'listed in MERGE_SENSITIVE - a scalar default '
                    'synthesized before the profile merge overwrites the '
                    'base\'s real value (3.3)')

    def test_only_the_feature_entries_are_open(self):
        open_at = []

        def walk(node, path):
            if isinstance(node, list):
                for i, v in enumerate(node):
                    walk(v, path + '.' + str(i))
                return
            if not isinstance(node, dict):
                return
            if True is node.get('`$OPEN`'):
                open_at.append(path)
            for k, v in node.items():
                walk(v, path + '.' + k)

        walk(config_shape(), '')
        self.assertEqual([
            '.profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`',
            '.profiles.`$CHILD`.feature.`$CHILD`',
            '.profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`',
        ], sorted(open_at))

if __name__ == '__main__':
    unittest.main()
