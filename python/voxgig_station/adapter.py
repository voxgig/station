# The station side of the plugin contract (design station.md 3), in ONE
# place: feature_binding() is what both entry paths delegate to -
#  - the GENERATED station feature (sdkgen-station's py template) calls
#    it from its init() and forwards its hook methods;
#  - the library's carried adapter (adapter_feature, the adopt/connect
#    retrofit for SDKs generated without the feature) is a thin shell
#    over the same call.
# Registration at init, wrap position verified, transport wrapped with
# copy-on-inject, hooks bridged to op events. Anything changed here
# changes both paths - which is the point.
#
# A port of typescript/src/adapter.ts, which is canonical. py-specific
# translations: the SDK's transport is synchronous (response, err)
# tuples, mock detection is the public client.mode, and the wrap-order
# guard counts by feature NAME - the py factory falls back to an inert
# BaseFeature (name 'base') for unknown names, so the features list may
# hold strays and indexes alone prove nothing.

import itertools
import time

from .error import StationError
from .station import Station

_corr_seq = itertools.count(1)


def _now_ms():
    return int(time.time() * 1000)


class FeatureBinding:
    """The hook bridge (design station.md 3 item 3): operation semantics
    correlated with the HTTP events via a per-operation id on the SDK's
    own ctx."""

    def __init__(self, station, slug):
        self._station = station
        self.slug = slug

    def PrePoint(self, opctx):
        opctx._station = {'corr': 'c' + str(next(_corr_seq)),
                          'start': _now_ms()}

    def PreDone(self, opctx):
        self._station._op_event(self.slug, opctx, _result_outcome(opctx))

    def PreUnexpected(self, opctx):
        self._station._op_event(self.slug, opctx, 'unexpected')


def feature_binding(ctx, fopts):
    """Resolve the station this activation binds to: an explicit handle
    in the feature options (connect/adopt and st.options() pass one - as
    a zero-arg callable, which rides the py SDK's option clone where an
    instance would not), else the ambient instance. No station open ->
    None: an activated feature with no opened station is an inert no-op
    that emits nothing and fails nothing (design station.md 3.1)."""
    fopts = fopts or {}
    handle = fopts.get('station')
    station = None
    if isinstance(handle, Station):
        station = handle
    elif callable(handle):
        got = handle()
        if isinstance(got, Station):
            station = got
    if station is None:
        station = Station.current()
    if station is None:
        return None

    client = ctx.client

    # Same construction, second arrival (generated feature + carried
    # adapter both active on one client): the first bind won, this one
    # is inert. See Station._bound_entry.
    if station._bound_entry(client) is not None:
        return None
    utility = ctx.utility
    options = ctx.options
    calleropts = fopts.get('calleropts')

    # Position guard (design station.md 3.3): the wrap must sit
    # immediately outside the base transport - inside retry/cache/
    # ratelimit - or its http events stop being wire truth. Position in
    # client.features IS init order, so verify it and fail loudly.
    # Counted by NAME: unknown activation entries become BaseFeature
    # strays in py, so never assume the list is exactly featureorder.
    names = [_feature_name(f) for f in client.features]
    self_at = names.index('station') if 'station' in names else -1
    test_at = names.index('test') if 'test' in names else -1
    expected = 0 if -1 == test_at else test_at + 1
    if self_at != expected:
        raise StationError(
            'station_wrap_order',
            'station must init immediately after the base transport; '
            'feature order is [' + ', '.join(names) + ']')

    binding, profile_plugin = station._register(
        client, ctx.config, options, calleropts, fopts)
    slug = binding['plugin']

    # Base URL precedence (design station.md 3.5): caller opts (7) beat
    # the profile (4), which beats the SDK's config default (1) already
    # in options.base. Applied only on the connect/adopt path, where the
    # caller opts are knowable.
    if calleropts is not None and calleropts.get('base') is None \
            and (profile_plugin or {}).get('base') is not None:
        options['base'] = profile_plugin['base']

    if 'none' != binding['rung']:
        placeholder = binding['placeholder']

        # A real credential already resident in the options is hoisted
        # into the broker and replaced by the placeholder before
        # construction completes (design station.md 3.1 adopt) -
        # options() and prepare() output become placeholder-safe from
        # here on.
        resident = options.get('apikey')
        if isinstance(resident, str) and '' != resident \
                and placeholder != resident:
            station._hoist(slug, resident)
        options['apikey'] = placeholder

    # Wrap the transport. Copy-on-inject (design station.md 5.3) happens
    # inside station._transport; auth-inactive plugins skip credential
    # planning but the wrap still observes.
    inner = utility.fetcher
    if True is getattr(inner, '__station__', False):
        raise StationError(
            'station_bound_twice',
            'plugin "' + slug + '" already carries a station wrap')

    def wrapped(fctx, fullurl, fetchdef):
        return station._transport(slug, inner, fctx, fullurl, fetchdef)

    wrapped.__station__ = True
    utility.fetcher = wrapped

    return FeatureBinding(station, slug)


def adapter_feature(station, calleropts):
    """The carried adapter: the retrofit path for SDKs generated without
    the station feature (design station.md 3.1 adopt). A duck-typed
    feature whose init/hooks delegate to feature_binding - it exists so
    connect/adopt work on any regenerated SDK, and it must stay
    behaviorally identical to the generated feature template in
    sdkgen-station."""
    return _CarriedAdapter(station, calleropts)


class _CarriedAdapter:
    def __init__(self, station, calleropts):
        self.version = '0.0.1'
        self.name = 'station'
        self.active = True
        # feature_add reads _options for positioning: immediately after
        # the test feature's base transport (design station.md 3.3). When
        # test is absent from the add order this is a no-op append, which
        # for a bare SDK still lands the wrap immediately outside the
        # base transport.
        self._options = {'__after__': 'test'}
        self._binding = None
        self._station = station
        self._calleropts = calleropts

    def get_name(self):
        return self.name

    def get_version(self):
        return self.version

    def get_active(self):
        return self.active

    def init(self, ctx, fopts):
        merged = dict(fopts or {})
        merged['station'] = self._station
        merged['calleropts'] = self._calleropts
        self._binding = feature_binding(ctx, merged)

    def PrePoint(self, ctx):
        if self._binding is not None:
            self._binding.PrePoint(ctx)

    def PreDone(self, ctx):
        if self._binding is not None:
            self._binding.PreDone(ctx)

    def PreUnexpected(self, ctx):
        if self._binding is not None:
            self._binding.PreUnexpected(ctx)


def _feature_name(f):
    name = getattr(f, 'name', None)
    if name is None and isinstance(f, dict):
        name = f.get('name')
    if name is None:
        get_name = getattr(f, 'get_name', None)
        if callable(get_name):
            name = get_name()
    return str(name or '')


def _result_outcome(ctx):
    result = getattr(ctx, 'result', None)
    if result is None:
        return 'unknown'
    if getattr(result, 'err', None) is not None:
        return 'err'
    if False is getattr(result, 'ok', None):
        return 'err'
    return 'ok'
