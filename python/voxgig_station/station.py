# The station library core, solo mode (design D1): fully functional
# in-process with no other component running. The proxy (D2) is a
# deferred amplifier - `require` therefore fails on the operation path
# (design station.md 2.1/14), and `auto` degrades to solo with one
# warning event.
#
# A port of typescript/src/Station.ts, which is canonical. Synchronous
# throughout: the py SDK pipeline is synchronous and its transport seam
# returns (response, err) tuples, so the middleware does too - and so do
# `load()` and `warm()`, which are async in ts/js (see the README).

import json
import re
import threading
import time
from urllib.parse import urlparse

from .descriptor import (
    canonical_serialize,
    normalize_descriptor,
    secretname_default,
)
from .error import StationError
from .events import EventBuffer
from .factory import factory_for, provide
from .feature import (
    check_features,
    check_pin,
    compose_features,
    feature_sources,
    merge_features,
    resolve_order,
)
from .loader import load_sync
from .profile import (
    config_scope,
    load_config,
    refapi,
    resolve_profile,
    select_profile,
)
from .secrets import SecretBroker, placeholder_for
from .shape import normalize_config, validate_config


def _now_ms():
    return int(time.time() * 1000)


def _first_non_empty(*vals):
    for v in vals:
        if v is not None and '' != v:
            return v
    return None


# The ref grammar is the JOINT identity model's (station-and-plugin.md 2,
# plugin design 4): a name is a package-ish specifier
# (`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`), a tag is not (`^[a-zA-Z0-9.~_-]+$`
# or empty - it MAY start with a digit because auto-tagging assigns
# integer tags, and admits neither `@` nor `/`); both cap at 1024; the
# split is on the FIRST `$`, so `a$b$c` is a good name with a bad tag.
_REF_NAME_RE = re.compile(r'[a-zA-Z@][a-zA-Z0-9.~_\-/]*\Z')
_REF_TAG_RE = re.compile(r'[a-zA-Z0-9.~_-]+\Z')
_REF_MAX = 1024


def check_instance_name(name):
    if not isinstance(name, str):
        return False
    if 0 == len(name) or _REF_MAX < len(name):
        return False
    return _REF_NAME_RE.match(name) is not None


def check_instance_tag(tag):
    if not isinstance(tag, str):
        return False
    # The empty tag is an ordinary tag: the single-instance case writes
    # no tag and never learns tags exist.
    if 0 == len(tag):
        return True
    if _REF_MAX < len(tag):
        return False
    return _REF_TAG_RE.match(tag) is not None


def _checkref(ref):
    """Validate a ref against the joint grammar and return its CANONICAL
    spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
    `stripe` are one registry key rather than two."""
    cut = ref.find('$')
    name = ref if -1 == cut else ref[:cut]
    tag = '' if -1 == cut else ref[cut + 1:]
    if not check_instance_name(name):
        raise StationError(
            'station_instance_api',
            'invalid instance name "' + name + '" in ref "' + ref + '": a '
            'name starts with a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, '
            'max 1024 (6.1)')
    if not check_instance_tag(tag):
        raise StationError(
            'station_instance_api',
            'invalid instance tag "' + tag + '" in ref "' + ref + '": a tag '
            'uses `[a-zA-Z0-9.~_-]`, max 1024 (6.1)')
    return name if '' == tag else ref


def _checkapi(api, ref):
    if refapi(ref) != api:
        raise StationError(
            'station_instance_api',
            'instance "' + ref + '" names api "' + refapi(ref) + '", but the '
            'SDK passed is api "' + api + '"; `as` is a tag, not a free name '
            '(6.1)')
    return ref


def instance_ref(api, fopts):
    """design 6.1: `as` IS A TAG, NOT A FREE NAME.

    The api comes from the SDK being passed, so the resulting ref is
    `<api>$<tag>` and multi-instance works imperatively too. A full ref
    is also accepted and is VALIDATED: its name must equal the SDK's api
    slug, or it is station_instance_api. An `as` that took an arbitrary
    name would reintroduce the second-identity problem the ref re-key
    removed.

    A bare connect(SDK) with no name falls back to the descriptor slug,
    which is today's behaviour and why the single-instance case is
    unchanged to the byte."""
    fopts = fopts or {}
    explicit = _first_non_empty(fopts.get('instance'))
    if explicit is not None:
        return _checkref(_checkapi(api, explicit))

    as_tag = _first_non_empty(fopts.get('as'))
    # The bare fallback is the SLUG - a name, never a ref: a `$` in it is
    # an invalid name, not an implicit tag.
    if as_tag is None:
        if not check_instance_name(api):
            raise StationError(
                'station_instance_api',
                'invalid instance name "' + str(api) + '": a name starts with '
                'a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)')
        return api

    # A full ref is validated against the api; a `$`-LESS STRING IS
    # ALWAYS A TAG and is joined to it. `as: 'stripe'` on api `stripe`
    # yields `stripe$stripe`, not `stripe`: 6.1 says twice and
    # emphatically that `as` is a tag rather than a free name, and a rule
    # with no exceptions is the one that ports the same way twenty times.
    # Someone who wants the untagged instance passes no `as` at all.
    return _checkref(api + '$' + as_tag if -1 == as_tag.find('$')
                     else _checkapi(api, as_tag))


class Station:
    _ambient = None
    _ambient_opts = None
    _ambient_lock = threading.Lock()

    # design 6.2's second path, and the front door the docs name.
    # Delegates to the same process-global table the free function fills;
    # there is one registry, not two.
    @classmethod
    def provide(cls, api, factory):
        provide(api, factory)

    # Ambient instance (design station.md 10.2): open() is the idempotent
    # process-wide singleton; a second open() with conflicting options is
    # an error; Station(opts) stays isolated for tests and multi-tenant
    # hosts. open() is non-blocking - solo involves no network, and the
    # deferred proxy probe must never change that.
    @classmethod
    def open(cls, opts=None):
        key = json.dumps(opts or {}, sort_keys=True, default=str)
        with cls._ambient_lock:
            if cls._ambient is not None:
                if key != cls._ambient_opts:
                    raise StationError(
                        'station_open_conflict',
                        'Station.open() was already called with different options')
                return cls._ambient
            cls._ambient = cls(opts)
            cls._ambient_opts = key
            return cls._ambient

    # The ambient instance, or None - never creates one. The generated
    # station feature binds through this when no explicit handle rides
    # its options (design station.md 3.1: binding is never implicit; only
    # open() creates the ambient instance).
    @classmethod
    def current(cls):
        return cls._ambient

    # Test seam: drop the ambient instance.
    @classmethod
    def reset(cls):
        with cls._ambient_lock:
            cls._ambient = None
            cls._ambient_opts = None

    def __init__(self, opts=None):
        self._opts = opts or {}

        # A caller passing config (even None) skips the file lookup -
        # mirrors the reference's undefined-vs-null distinction.
        if 'config' in self._opts:
            config = self._opts['config']
        else:
            config = load_config(self._opts.get('folder'))

        # design 6.3: EXPLICIT WINS, then an in-code config (the
        # application wrote it, so it is repo-scoped by construction),
        # then where the file was found. Inferring BEFORE reading the
        # explicit option is a real precedence bug: it makes
        # `repo_scoped: False` unsettable for any caller passing a config
        # in code, which is every test of the rule.
        if self._opts.get('repo_scoped') is not None:
            self.repo_scoped = bool(self._opts['repo_scoped'])
        elif 'config' in self._opts:
            self.repo_scoped = True
        else:
            self.repo_scoped = 'user' != config_scope(self._opts.get('folder'))

        # Normalize, then validate (design 4.2). A malformed station.json
        # fails open() with EVERY error at once - an eighteen-instance
        # config must not die because the eighteenth has a typo'd package
        # name.
        #
        # resolve_profile then reads the RAW config, NOT the normalized
        # one. The normalized form is an input to validation and to
        # nothing else: block defaults synthesized before the profile
        # merge would let a one-key overlay overwrite the base's
        # `active: False` and silently re-enable a barred integration
        # (design 3.3, 4.2).
        if config is not None:
            validate_config(normalize_config(config))

        # The raw config, kept for 8.7's provenance: the resolved profile
        # has already collapsed the levels that provenance has to name.
        self.raw = config
        self._profile = resolve_profile(
            config, select_profile(self._opts.get('profile')))
        self._broker = SecretBroker(self._profile['providers'])
        self._buffer = EventBuffer()
        self._registry = {}
        # design 6.1: `sdk(name)` caches; `create()` deliberately does not.
        self._clients = {}
        # An auto-assigned tag to the DECLARED instance it stands for
        # (5.3). Kept beside the registry rather than inside it because
        # the mapping exists before construction, and `block_for` needs
        # it during registration.
        self._alias_of = {}
        # 7.4: the shared per-api descriptor cache - see describe().
        self._descriptor_cache = {}
        self._closed = False
        self._lock = threading.Lock()

        proxy = self._opts.get('proxy')
        proxy = 'auto' if proxy is None else proxy
        self._require_proxy = 'require' == proxy

        if 'auto' == proxy:
            # The probe is deferred with the proxy itself; absence
            # degrades to solo with a single warning event naming the
            # cause (design station.md 14).
            self._emit({
                't': _now_ms(), 'kind': 'station',
                'meta': {'warn': 'proxy absent (not found); running solo'},
            })

    # --- binding forms (design station.md 3.1) ---

    def connect(self, SDK, opts=None):
        """connect(SDK, opts): station constructs the SDK itself,
        activating the adapter with the 3.3 ordering. The activation
        entry plus the extend-supplied instance ride the tolerance added
        to the generated constructor (sdkgen 9.3 change)."""
        return self._construct(SDK, opts)

    def adopt(self, SDK, opts=None):
        """adopt(SDK, opts): the retrofit path - construction-time sugar,
        not post-hoc attachment (design station.md 3.1). In py it is the
        same construction as connect; a resident options apikey is
        hoisted by the adapter."""
        return self._construct(SDK, opts)

    def _construct(self, SDK, opts=None):
        from .adapter import adapter_feature

        if self._closed:
            raise StationError('station_no_plugin', 'station is closed')
        opts = opts or {}

        # calleropts must survive the SDK's option pipeline (vs.clone
        # flattens arbitrary objects), so any extend instances are left
        # out of the carried copy - the binding only reads plain keys.
        calleropts = {k: v for k, v in opts.items() if 'extend' != k}

        fmap = dict(opts.get('feature') or {})
        entry = dict(fmap.get('station') or {})
        entry.update({
            'active': True,
            # A zero-arg callable, not the instance: callables ride the
            # py SDK's option clone by reference, objects do not.
            'station': self._handle(),
            'calleropts': calleropts,
        })
        # design 6.1: `as` is a TAG, resolved against the api in
        # _register - the api comes from the SDK being passed and is not
        # knowable here until that SDK's config has been normalized.
        if opts.get('as') is not None:
            entry['as'] = opts['as']
        if opts.get('instance') is not None:
            entry['instance'] = opts['instance']
        fmap['station'] = entry

        options = dict(opts)
        options['feature'] = fmap
        # The carried adapter rides extend for SDKs generated WITHOUT
        # the station feature; when the generated class exists the
        # constructor uses it and the extend copy is skipped by name
        # (both delegate to feature_binding, so behavior is identical).
        options['extend'] = list(opts.get('extend') or []) + \
            [adapter_feature(self, calleropts)]
        return SDK(options)

    def options(self, a=None, b=None):
        """Inverted binding (design station.md 3.1): build the plain
        options map a generated constructor already accepts - the handle,
        the activation entry, and the caller's own opts.

        design 6.1: `options(instance_name?, extra?)`. The name is
        OPTIONAL AND LEADING, so every existing `options({...})` call is
        unchanged - the inverted binding is the static languages' path
        and they need to say which instance they are building without a
        second method."""
        named = isinstance(a, str)
        instance = a if named else None
        extra = (b if named else a) or {}
        calleropts = {k: v for k, v in extra.items() if 'extend' != k}
        fmap = dict(extra.get('feature') or {})
        entry = dict(fmap.get('station') or {})
        entry.update({
            'active': True,
            'station': self._handle(),
            'calleropts': calleropts,
        })
        if instance is not None:
            entry['instance'] = instance
        fmap['station'] = entry
        out = dict(extra)
        out['feature'] = fmap
        return out

    def _handle(self):
        # The options-borne handle: a callable returning this station.
        # feature_binding accepts the instance, the callable, or falls
        # back to the ambient instance.
        return lambda: self

    # --- registration (design station.md 3 item 1, called by the adapter) ---

    def _bound_entry(self, client):
        """The registry entry whose client IS this object, or None. Used
        by feature_binding for idempotency: connect/adopt activate the
        station entry AND ride the carried adapter on extend, so on an
        SDK whose generated config carries a real station feature class
        the same construction reaches feature_binding twice - the second
        arrival must no-op, while a genuinely second client of the same
        instance still fails _register's name check (10.2)."""
        with self._lock:
            for entry in self._registry.values():
                if entry['client'] is client:
                    return entry
        return None

    def block_for(self, name):
        """The profile block that governs an instance - its own if the
        profile declares it, otherwise its API'S.

        resolve_profile builds `profile.sdk` from the declared refs alone
        ("an api block declares no instance, so the ref set comes from
        the two `sdk` maps"), shallow-merging `profile.api[a]` into each.
        That is right for a declared instance and leaves an IMPERATIVE
        one - connect(SDK, {'as': 'test'}), named but never written into
        config - with no block at all. The api-level `secret`, `base` and
        most seriously `policy.hosts` then did not reach it, so a profile
        that denies egress everywhere denied nothing for a tagged client.

        ONE RULE, ONE PLACE: registration and the transport seam both ask
        here, because them disagreeing is how the credential and the
        allowlist came apart in the first place."""
        block = self._profile['sdk'].get(self.declared_ref(name))
        if block is None:
            block = self._profile['api'].get(refapi(name))
        return block

    def declared_ref(self, name):
        """The DECLARED instance an assigned tag stands for, or the name
        itself. create('stripe$prod') registers under `stripe$1`, and
        every question about that client's configuration - its secret,
        its base, its egress policy - is a question about
        `stripe$prod`."""
        return self._alias_of.get(name, name)

    def _register(self, client, config, options, _calleropts, fopts=None):
        descriptor, warnings = self.describe(config, (options or {}).get('feature'))
        api = descriptor['slug']

        # 7.5: station knows the instance name before construction begins
        # and passes it through the feature options. A bare connect(SDK)
        # with no name falls back to the descriptor slug, which is
        # today's behaviour and why the single-instance case is unchanged.
        name = instance_ref(api, fopts)

        with self._lock:
            # 7.1: the check moves to the instance key. Two clients of
            # one api is the NORMAL case now; two bindings of one
            # instance is still the error it was.
            if name in self._registry:
                raise StationError(
                    'station_bound_twice',
                    'instance "' + name + '" is already registered; binding '
                    'one client twice is an error (10.2)')

            profile_plugin = self.block_for(name)
            # Secret name precedence: the feature option (in-code, design
            # station.md 9 config.options.secret) beats the profile,
            # which beats the INSTANCE-derived default - and the default
            # takes the DECLARED name, not the assigned tag, so every
            # per-request client of one instance shares one broker cache
            # entry (5.3).
            #
            # The descriptor's own `auth.secretname` stays the API-level
            # default and is NOT used here (7.4): one descriptor is
            # shared by every instance of an api and cannot hold two
            # instance-derived names.
            secretname = _first_non_empty(
                (fopts or {}).get('secret'),
                (profile_plugin or {}).get('secret'),
            ) or secretname_default(self.declared_ref(name))

            rung = 'R1' if descriptor['auth']['active'] else 'none'
            binding = {
                'plugin': name,
                'api': api,
                # 7.2: two live instances of one api MUST have distinct
                # placeholders or the injection seam cannot tell which
                # credential a header wants.
                'placeholder': placeholder_for(name)
                if descriptor['auth']['active'] else None,
                'secretname': secretname
                if descriptor['auth']['active'] else None,
                'rung': rung,
            }

            self._registry[name] = {
                'name': name, 'api': api, 'descriptor': descriptor,
                'rung': rung, 'client': client, 'warnings': warnings,
                'secretname': secretname
                if descriptor['auth']['active'] else None,
            }

        for w in warnings:
            self._emit({'t': _now_ms(), 'kind': 'station', 'plugin': name,
                        'api': api, 'meta': {'warn': w}})
        self._emit({
            't': _now_ms(), 'kind': 'construct', 'plugin': name, 'api': api,
            'meta': {'name': descriptor['name'],
                     'version': descriptor['version'], 'rung': rung},
        })

        return binding, profile_plugin

    def describe(self, config, _feature=None):
        """7.4: THE DESCRIPTOR IS SHARED, because it describes the api
        rather than any use of it. normalize_descriptor runs once per api
        and every instance of that api holds a reference to the same
        object - at 26 instances over 20 apis that is 20 normalizations,
        not 26, and the canonical serialization the proxy dedupes
        registrations by is computed once per api too.

        Normalized with NO per-instance features, so the shared value
        holds only API-stable metadata - which is what factory.py already
        does at provide time. Per-instance activation is
        features_of(name)'s answer; a cache keyed by slug but built from
        the first instance's feature map would make descriptor_of()
        construction-order-dependent."""
        slug = str(((config or {}).get('main') or {}).get('slug') or '')
        if '' != slug:
            hit = self._descriptor_cache.get(slug)
            if hit is not None:
                return hit
        out = normalize_descriptor(config, None)
        self._descriptor_cache[out[0]['slug']] = out
        return out

    def _hoist(self, name, value):
        self._broker.hoist(name, value)
        self._emit({
            't': _now_ms(), 'kind': 'station', 'plugin': name,
            'api': refapi(name),
            'meta': {
                'warn': 'a resident credential was hoisted into the broker '
                        'and replaced by the placeholder; prefer configuring '
                        'the secret name and letting sekreto resolve it',
            },
        })

    # --- the transport middleware (design station.md 3.3, 5.3) ---

    def _transport(self, name, inner, fctx, fullurl, fetchdef):
        """The wrap installed by the adapter, keyed by INSTANCE. py
        transport contract: a (response, err) tuple, and features may
        also see raised exceptions - both shapes are preserved."""
        # Fail-closed means traffic (design station.md 2.1): with the
        # proxy deferred, `require` can never attach, so every operation
        # fails here - the operation path, never the constructor.
        if self._require_proxy:
            err = StationError('station_no_proxy',
                               'proxy: "require" is set and no proxy is attached')
            self._emit_err(name, fctx, err)
            return None, err

        with self._lock:
            entry = self._registry.get(name)
        placeholder = placeholder_for(name)
        # Mock detection: the py SDK's public mode attribute
        # (design station.md 3.3 - never inject into mock transports).
        client = getattr(fctx, 'client', None)
        live = 'live' == getattr(client, 'mode', None)
        profile_plugin = self.block_for(name) or {}

        # Egress policy (design station.md 16), solo half: the hosts
        # allowlist is enforced at the seam every request crosses. When a
        # policy is present, redirects come back manual - a 3xx is a
        # response like any other, so a Location off the allowlist cannot
        # pull an automatic credentialed follow-up to an unapproved host
        # (8.2's rule, applied at the library seam).
        hosts = (profile_plugin.get('policy') or {}).get('hosts')
        if hosts is not None and live:
            hostname = ''
            try:
                hostname = urlparse(fullurl).hostname or ''
            except Exception:
                pass
            if hostname not in hosts:
                err = StationError(
                    'station_host_allow',
                    'egress to "' + hostname + '" denied by the hosts policy '
                    'of plugin "' + name + '"')
                self._emit_err(name, fctx, err)
                return None, err

        senddef = fetchdef
        if hosts is not None and live:
            senddef = dict(senddef or {})
            senddef['redirect'] = 'manual'

        # Injection: at the last boundary, below every recording feature,
        # and never into mock transports (3.3) - in test/mock modes the
        # placeholder rides through untouched, so real credentials never
        # enter in-memory mock stores. Copy-on-inject: the object graph
        # reachable from ctx/spec/ctrl keeps the placeholder, ever (5.3).
        if live and entry is not None and 'R1' == entry['rung']:
            # 7.4: THE EFFECTIVE NAME, resolved once at registration and
            # stored on the entry. Re-deriving it here gets the
            # precedence right and the FALLBACK wrong:
            # `descriptor.auth.secretname` is the API-level default, and
            # one descriptor is shared by every instance of an api - so a
            # tagged instance with no explicit `secret` would read
            # `stripe.apikey` where registration recorded
            # `stripe_test.apikey`. NO FALLBACK: this branch is guarded
            # by the same condition that populates the field.
            secretname = entry['secretname']

            try:
                value = self._broker.value(name, secretname)
            except Exception as e:
                self._emit_err(name, fctx, e)
                return None, e

            senddef = dict(senddef or {})
            senddef['headers'] = dict(senddef.get('headers') or {})
            for h, v in list(senddef['headers'].items()):
                if isinstance(v, str) and placeholder in v:
                    senddef['headers'][h] = v.replace(placeholder, value)

        st = getattr(fctx, '_station', None) or {}
        corr = st.get('corr')
        started = _now_ms()

        try:
            res, err = inner(fctx, fullurl, senddef)
        except Exception as e:
            self._emit_http(name, corr, fullurl, senddef, 0, started, 0)
            self._emit_err(name, fctx, e)
            raise

        if err is not None:
            self._emit_http(name, corr, fullurl, senddef, 0, started, 0)
            self._emit_err(name, fctx, err)
            return res, err

        status = 0
        nbytes = 0
        if isinstance(res, dict):
            s = res.get('status')
            if isinstance(s, (int, float)) and not isinstance(s, bool):
                status = int(s)
            headers = res.get('headers')
            if isinstance(headers, dict):
                cl = headers.get('content-length')
                if cl is not None:
                    try:
                        nbytes = int(cl)
                    except (TypeError, ValueError):
                        nbytes = 0
        self._emit_http(name, corr, fullurl, senddef, status, started, nbytes)

        return res, err

    def _emit_http(self, name, corr, fullurl, fetchdef, status, started, nbytes):
        host = ''
        path = ''
        try:
            u = urlparse(fullurl)
            host = u.netloc
            path = u.path
        except Exception:
            path = fullurl
        ev = {
            't': started, 'kind': 'http', 'plugin': name, 'api': refapi(name),
            'http': {
                'method': (fetchdef or {}).get('method') or 'GET',
                'host': host, 'path': path, 'status': status,
                'durationMs': _now_ms() - started, 'bytes': nbytes,
            },
        }
        if corr is not None:
            ev['corr'] = corr
        self._emit(ev)

    def _emit_err(self, name, fctx, err):
        st = getattr(fctx, '_station', None) or {}
        ev = {
            # 7.3's grouping contract: `plugin` is the INSTANCE and `api`
            # is what groups its siblings. Construction events carrying
            # both while runtime events carried only one is grouping that
            # works exactly until it is used.
            't': _now_ms(), 'kind': 'error', 'plugin': name,
            'api': refapi(name),
            'err': {
                'code': getattr(err, 'code', None),
                # The scrub keeps an upstream echo of a credential out of
                # the event stream (design station.md 7 as revised:
                # exact-value, no length floor).
                'message': self.redact(str(err)),
            },
        }
        if st.get('corr') is not None:
            ev['corr'] = st.get('corr')
        self._emit(ev)

    def _op_event(self, name, ctx, outcome):
        """Op events from the hook bridge (design station.md 3 item 3)."""
        st = getattr(ctx, '_station', None) or {}
        op = getattr(ctx, 'op', None)
        # The py SDK's Operation uses '_' as its no-entity/no-op sentinel;
        # the descriptor's spelling is the entity's own name.
        entity = getattr(op, 'entity', None)
        if entity in (None, '', '_'):
            ent = getattr(ctx, 'entity', None)
            get_name = getattr(ent, 'get_name', None)
            entity = get_name() if callable(get_name) else ''
        opname = getattr(op, 'name', None)
        if opname in (None, '_'):
            opname = ''
        ev = {
            't': _now_ms(), 'kind': 'op', 'plugin': name, 'api': refapi(name),
            'op': {
                'entity': str(entity),
                'op': str(opname),
                'outcome': outcome,
                'durationMs': (_now_ms() - st['start'])
                if st.get('start') is not None else 0,
            },
        }
        if st.get('corr') is not None:
            ev['corr'] = st.get('corr')
        self._emit(ev)

    # --- the query/observe surface (design station.md 3.2, 6) ---

    def plugins(self):
        """One entry per LIVE INSTANCE (6.1), and EXHAUSTIVE:
        auto-tagged entries are not collapsed here, because inspection,
        health reporting and cleanup all need to enumerate the clients
        create() produced, which is exactly when you most want them.
        Truncation is a presentation decision and belongs to status()."""
        with self._lock:
            return [{
                'name': e['name'],
                'api': e['api'],
                # Retained: it is the api, which is what `slug` always
                # meant here, and dropping it would break every consumer
                # for no gain while the two are equal for untagged
                # instances.
                'slug': e['api'],
                'descriptor': e['descriptor'],
                'rung': e['rung'],
                'secretname': e['secretname'],
                'warnings': list(e['warnings']),
            } for e in self._registry.values()]

    # --- the declarative front door (design station.md 6) ---

    def sdk(self, name):
        """The instance, constructed on first call and CACHED: same name
        -> same object. That caching is what makes "get it where you need
        it" a real instruction - call it in a request handler, in a
        worker, in a test, and the first call pays construction while the
        rest are a map lookup. SYNCHRONOUS (6.3)."""
        cached = self._clients.get(name)
        if cached is not None:
            return cached
        client = self._build(name, None)
        self._clients[name] = client
        return client

    def create(self, name, overrides=None):
        """An UNCACHED client from the same resolved config plus
        overrides, for the case that genuinely wants a distinct one - a
        per-request credential scope, a test double. Deliberately the
        longer name.

        It registers under an AUTO-ASSIGNED TAG, because registration
        keys on the instance name and station_bound_twice fires on a
        second binding of one name: a second create('stripe') would
        otherwise throw, which is exactly the per-request case this
        exists for. The tag is the lowest unused positive integer, so an
        auto-tagged instance is an ORDINARY instance rather than a
        parallel identity scheme.

        The SECRET NAME does not follow the assigned tag: it resolves
        from the DECLARED instance the tag was assigned under, so every
        client of one instance shares one broker cache entry (5.3)."""
        return self._build(name, self.auto_tag(name), overrides)

    def auto_tag(self, name):
        """The lowest positive integer tag not already taken, by a LIVE
        instance or a DECLARED one.

        THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare
        `stripe$1`, and until something constructs it the registry says
        false - so create('stripe$prod') would take that identity,
        instances() would report the declared `stripe$1` as live with the
        wrong client, and a later sdk('stripe$1') would fail
        station_bound_twice against a binding that was never its own.
        Declaration reserves the name whether or not it has been built."""
        api = refapi(name)
        n = 1
        while True:
            ref = api + '$' + str(n)
            with self._lock:
                live = ref in self._registry
            if not live and self._profile['sdk'].get(ref) is None:
                return ref
            n += 1

    def _build(self, name, assigned=None, overrides=None):
        """The shared construction path behind sdk() and create()."""
        from .adapter import adapter_feature

        if self._closed:
            raise StationError('station_no_plugin', 'station is closed')

        block = self._profile['sdk'].get(name)
        if block is None:
            raise StationError(
                'station_no_instance',
                'no declared instance "' + str(name) + '"; declared: [' +
                ', '.join(sorted(self._profile['sdk'].keys())) + ']')
        if False is block.get('active'):
            raise StationError(
                'station_instance_inactive',
                'instance "' + name + '" is declared with `active: false`, '
                'which bars it from running while keeping it visible in '
                'instances()')

        api = refapi(name)
        entry = self.resolve_factory(api, block)

        # 8.5 VALIDATES HERE, not only in check(). The schema arrives
        # with the factory, so the moment a factory is resolved is the
        # first moment validation is possible - and running it in
        # check() alone left two gaps: production sdk() silently ignored
        # an unknown option like `retry.retires`, and check() itself
        # missed the case where the factory is discovered by the LOADER
        # (its pre-check sees no registered factory, then sdk() loads and
        # constructs unvalidated). One call here closes both, because
        # EVERY path to a constructor comes through this line.
        resolved = self.features_of(name)
        faults = check_features(resolved['merged'], entry['descriptor'])
        if 0 < len(faults):
            raise StationError(faults[0]['code'],
                               '; '.join(f['message'] for f in faults))

        # 8.4: compose the merged feature map into the ORDERED form and
        # hand it to the constructor. No new seam - it is the same
        # `options.feature` map connect() already uses for station's own
        # placement, with more in it, and a py dict preserves insertion
        # order so the order rides the map.
        #
        # Station's own entry is composed AFTER the user merge and always
        # wins (8.4), which is why `station` is dropped here and added by
        # options(): a config file that can switch off the component
        # reading it is not a surface, it is a trap. `feature.station` is
        # already station_feature_reserved at validation, so this is the
        # second half of one rule rather than a second rule.
        fmap = {}
        ordered = [o for o in resolve_order(resolved['merged'])
                   if 'station' != o['name']]
        for f in compose_features(ordered):
            rest = dict(f)
            fname = rest.pop('name')
            fmap[fname] = rest

        opts = dict(block.get('options') or {})
        if block.get('base') is not None:
            opts['base'] = block['base']
        opts.update(overrides or {})
        feature = dict(fmap)
        feature.update((overrides or {}).get('feature') or {})
        opts['feature'] = feature

        # 5.3: THE ALIAS IS RECORDED, NOT THE FIELDS. Carrying the
        # declared `secret` through the feature options and stopping
        # there leaves `policy`, `base` and everything else behind, so an
        # auto-tagged client silently loses its declared instance's HOSTS
        # ALLOWLIST and falls back to the wider api-level one. Recording
        # what the tag STANDS FOR is one rule that every lookup already
        # goes through.
        #
        # Only when the tag was ASSIGNED - a caller naming its own is
        # naming an instance, not aliasing one.
        if assigned is not None and assigned != name:
            self._alias_of[assigned] = name

        # ...AND THE CARRIED ADAPTER RIDES `extend`, exactly as it does
        # on connect. The 3.1 retrofit case - an SDK generated before the
        # station feature, which factory_from_module explicitly supports
        # - has no generated feature to consume the `feature.station`
        # activation this path sets, so a declarative sdk() without this
        # either fails on an unknown feature or returns an unregistered,
        # unwrapped client with no credential injection and no events.
        #
        # Safe on a REGENERATED SDK too: the constructor uses its own
        # station feature and skips the extend copy by name, and both
        # delegate to feature_binding, whose _bound_entry check no-ops a
        # second arrival for the same client.
        with_adapter = dict(opts)
        with_adapter['extend'] = list(opts.get('extend') or []) + \
            [adapter_feature(self, opts)]

        # The instance name reaches the adapter the same way it does on
        # the imperative path, so registration has one spelling (7.5).
        return entry['construct'](
            self.options(assigned if assigned is not None else name,
                         with_adapter))

    def resolve_factory(self, api, block):
        """6.2's three paths, in order of preference: self-registration,
        Station.provide, then the loader."""
        direct = factory_for(api)
        if direct is not None:
            return direct

        pkg = self.loader_package(api, block)
        if pkg is not None:
            load_sync(api, pkg, (block or {}).get('export'))
            loaded = factory_for(api)
            if loaded is not None:
                return loaded

        raise StationError(
            'station_no_factory',
            'no factory for api "' + api + '"; either import a generated '
            'package that self-registers, call Station.provide("' + api +
            '", ...), or set `api.' + api + '.package` so the loader can '
            'import it')

    def loader_package(self, api, block):
        """`package` is honoured only from repo-scoped config (6.3), and
        a user-level one is IGNORED WITH A WARNING rather than imported -
        it names code to load and sits outside the repo's review
        boundary."""
        pkg = (block or {}).get('package')
        if pkg is None or '' == pkg:
            return None
        if False is self._opts.get('load'):
            return None

        if not self.repo_scoped:
            self._emit({
                't': _now_ms(), 'kind': 'station', 'plugin': api, 'api': api,
                'meta': {
                    'warn': 'ignoring `package` for api "' + api + '": it '
                            'came from a user-level station.json, which is '
                            'outside the repo\'s review boundary; everything '
                            'else in that config still applies',
                },
            })
            return None
        return pkg

    def load(self):
        """Preload every declared active instance's package into the
        factory table.

        py-specific: SYNCHRONOUS, and never required. ts/js need
        `await station.load()` because an ESM-only package cannot be
        loaded from a synchronous `sdk()`; py has one module system, so
        `sdk()` loads whatever `load()` would have. It is kept because
        loading the fleet at startup - where an import error is one
        failure at a moment somebody is watching - is worth having."""
        if False is self._opts.get('load'):
            return
        for name in sorted(self._profile['sdk'].keys()):
            block = self._profile['sdk'][name]
            if False is block.get('active'):
                continue
            api = refapi(name)
            if factory_for(api) is not None:
                continue
            pkg = self.loader_package(api, block)
            if pkg is None:
                continue
            load_sync(api, pkg, block.get('export'))

    def features_of(self, name):
        """The merged, ordered feature set for one instance, WITH
        PROVENANCE (design 8.7): which config level set each value.

        Provenance is the half that makes a fleet view usable rather than
        merely correct - at 26 instances "why is retry off here" is the
        question, and a merged map alone cannot answer it."""
        api = refapi(name)
        profiles = (self.raw or {}).get('profiles') or {}
        base = profiles.get('default') or {}
        overlay = {} if 'default' == self._profile['name'] \
            else (profiles.get(self._profile['name']) or {})

        levels = [
            'default.feature', 'default.api', 'default.sdk',
            self._profile['name'] + '.feature',
            self._profile['name'] + '.api',
            self._profile['name'] + '.sdk',
        ]
        sources = feature_sources(base, overlay, api, name)

        # Last writer per (feature, key) wins, and the level that wrote
        # it is what `from` records.
        provenance = {}
        for i, src in enumerate(sources):
            if not isinstance(src, dict):
                continue
            for fname, entry in src.items():
                if not isinstance(entry, dict):
                    continue
                at = provenance.setdefault(fname, {})
                for k in entry:
                    at[k] = levels[i]

        merged = merge_features(sources)

        # Policy budget (design 16): rps/concurrency ceilings ride "the
        # SDK `ratelimit` feature, configured by station". Composed HERE,
        # into the merged map every consumer reads, rather than patched
        # in at construction alone - so _build() orders it with the
        # ordinary constraint-and-band rules, check()'s 8.5 pass
        # validates it against the SDK's own declaration (a budget on an
        # SDK with no ratelimit feature is station_feature_unknown, not a
        # setting that quietly did nothing), and the 8.7 fleet view
        # answers "is ratelimit on?" truthfully.
        #
        # `rps` maps to the token bucket's refill `rate` (per second -
        # the same unit); `concurrency` to its capacity `burst`, the
        # number of requests that can be in flight from a full bucket.
        # POLICY WINS over a `feature.ratelimit` config entry on the keys
        # it sets - it is enforcement, not a default - and other tuning
        # keys survive beside it.
        budget = ((self.block_for(name) or {}).get('policy') or {}).get('budget')
        if isinstance(budget, dict):
            prior = merged.get('ratelimit')
            entry = dict(prior) if isinstance(prior, dict) else {}
            entry['active'] = True
            at = provenance.setdefault('ratelimit', {})
            at['active'] = 'policy.budget'
            if budget.get('rps') is not None:
                entry['rate'] = budget['rps']
                at['rate'] = 'policy.budget'
            if budget.get('concurrency') is not None:
                entry['burst'] = budget['concurrency']
                at['burst'] = 'policy.budget'
            merged = dict(merged)
            merged['ratelimit'] = entry

        # THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station`
        # is never in `merged` - `feature.station` is reserved and
        # rejected at validation (8.4) - so without it check_pin finds no
        # station row and is a PERMANENT NO-OP: a constraint like
        # `retry.order.after: 'station'` would be treated as vacuous
        # rather than rejected, and the reported order would omit the one
        # feature whose position is supposedly pinned.
        #
        # Added here rather than into `merged`, which stays the user's
        # own merge result.
        for_order = dict(merged)
        for_order['station'] = {'active': True}
        ordered = resolve_order(for_order)
        check_pin(ordered)
        return {'ordered': [o['name'] for o in ordered],
                'merged': merged, 'from': provenance}

    def features(self, filter=None):
        """The fleet feature view: instance x feature, effective options,
        and which config level set each (8.7).

        8.7's documented shape is an OBJECT, and only the object form can
        express the question the view exists for: `{'feature': 'debug'}`
        - "is debug on anywhere?", the one that is twenty greps today.
        The string form is kept as shorthand for "this instance or this
        api"."""
        loose = isinstance(filter, str)
        f = {'instance': filter, 'api': filter} if loose \
            else dict(filter or {})

        rows = []
        for r in self.instances():
            if loose:
                keep = f['instance'] is None or \
                    r['name'] == f['instance'] or r['api'] == f['api']
            else:
                keep = True
                if f.get('instance') is not None and \
                        r['name'] != f['instance'] and \
                        r['api'] != f['instance']:
                    keep = False
                elif f.get('api') is not None and r['api'] != f['api']:
                    keep = False
            if not keep:
                continue
            row = {'instance': r['name'], 'api': r['api']}
            row.update(self.features_of(r['name']))
            rows.append(row)

        # `feature` filters the ROWS, not the instances: an instance that
        # does not carry the named feature is not part of the answer, and
        # the rows that remain are narrowed to it so the view answers
        # "where is debug on, and with what" rather than "here is
        # everything, go and look".
        want = None if loose else f.get('feature')
        if want is None:
            return rows
        return [{
            'instance': row['instance'],
            'api': row['api'],
            'ordered': [n for n in row['ordered'] if n == want],
            'merged': {want: row['merged'][want]},
            'from': {want: row['from'].get(want) or {}},
        } for row in rows if row['merged'].get(want) is not None]

    def check(self):
        """Eagerly resolve and construct every ACTIVE instance - for CI
        (6.6). The point is to turn availability errors, which are
        deliberately deferred to first use, into ONE failure at a moment
        somebody is watching."""
        ok = []
        failed = []
        for row in self.instances():
            if not row['active']:
                continue
            try:
                # 8.5 runs FIRST and needs no construction: the schema
                # arrives with the factory, not with a live client, so a
                # feature typo is a CI failure rather than a setting that
                # quietly did nothing in production.
                entry = factory_for(row['api'])
                if entry is not None:
                    faults = check_features(
                        self.features_of(row['name'])['merged'],
                        entry['descriptor'])
                    if 0 < len(faults):
                        failed.append({
                            'name': row['name'], 'code': faults[0]['code'],
                            'message': '; '.join(f['message'] for f in faults),
                        })
                        continue
                self.sdk(row['name'])
                ok.append(row['name'])
            except Exception as e:
                failed.append({'name': row['name'],
                               'code': getattr(e, 'code', None),
                               'message': str(e)})
        return {'ok': ok, 'failed': failed}

    def warm(self, names=None):
        """Batch-resolve secrets for ACTIVE instances (5.5).

        With no argument it warms the active ones only, because reaching
        for a credential belonging to a disabled integration is the wrong
        default. warm(names) warms exactly what it is given, inactive
        included, because an explicit name is an explicit request.

        py-specific: SERIAL over the DEDUPLICATED secret names, where
        ts/js resolve them concurrently. This port is synchronous
        throughout and sekreto's py port is too, so there is no await to
        overlap; the deduplication is what the method exists for either
        way - the broker's resolution cache is keyed by SECRET NAME
        (5.3), so several instances sharing one api-level `secret` cost
        one round-trip rather than one each."""
        if names is not None:
            wanted = list(names)
        else:
            wanted = [r['name'] for r in self.instances() if r['active']]

        plan = []
        warmed = []
        missed = []
        for name in wanted:
            # THE REGISTRY IS THE AUTHORITY: a registered instance
            # already carries the resolved name, in-code `secret` feature
            # option included (design 9). A NAME NOBODY DECLARED OR
            # REGISTERED IS A MISS, not a lookup - a wider fallback would
            # let a typo like `stripe$prodd` derive a secret name and
            # call the provider, so a nonexistent instance could be
            # reported `warmed` off a shared api-level credential.
            # Registered OR declared, and nothing else.
            with self._lock:
                entry = self._registry.get(name)
            if entry is None and self._profile['sdk'].get(name) is None:
                missed.append(name)
                continue
            secretname = (entry or {}).get('secretname')
            if secretname is None:
                secretname = (self.block_for(name) or {}).get('secret') or \
                    secretname_default(self.declared_ref(name))
            plan.append((name, secretname))

        # One resolution per distinct secret name; the per-instance
        # results are mapped back afterwards so the reported shape is
        # unchanged.
        bysecret = {}
        for name, secretname in plan:
            bysecret.setdefault(secretname, []).append(name)

        for secretname, snames in bysecret.items():
            try:
                self._broker.value(snames[0], secretname)
                warmed.extend(snames)
            except Exception:
                missed.extend(snames)

        return {'warmed': sorted(warmed), 'missed': sorted(missed)}

    def instances(self):
        """Every DECLARED instance (6.1) - a different question from
        plugins(), and the answers differ routinely: a lazily-started
        instance is `active: True` and not yet live."""
        sdk = self._profile['sdk']
        out = []
        for name in sorted(sdk.keys()):
            with self._lock:
                entry = self._registry.get(name)
            out.append({
                'name': name,
                'api': refapi(name),
                # `active: False` means BARRED FROM RUNNING - a
                # declaration that stays in the file and here while being
                # refused a client.
                'active': False is not sdk[name].get('active'),
                'live': entry is not None,
                'rung': entry['rung'] if entry is not None else 'none',
                'block': sdk[name],
            })
        return out

    def descriptor_of(self, name):
        """7.4: accepts an INSTANCE name and returns its api's descriptor
        - one object shared by every instance of that api."""
        with self._lock:
            entry = self._registry.get(name)
            known = list(self._registry.keys())
        if entry is None:
            raise StationError(
                'station_no_plugin',
                'unknown plugin "' + str(name) + '"; known: [' +
                ', '.join(known) + ']')
        return entry['descriptor']

    def canonical_descriptor(self, name):
        return canonical_serialize(self.descriptor_of(name))

    def events(self):
        return self._buffer.events()

    def tap(self, fn):
        return self._buffer.tap(fn)

    def status(self):
        return {
            'mode': 'solo',
            'profile': self._profile['name'],
            # 7.1: the registry is keyed by INSTANCE, so a status page
            # that projects only `slug` shows two indistinguishable rows
            # for `stripe$test` and `stripe$live` and omits the names it
            # is keyed by - an operator cannot tell which one is
            # unhealthy. `slug` stays for compatibility; `name` and `api`
            # are what answer the question.
            'plugins': [{'name': p['name'], 'api': p['api'],
                         'slug': p['slug'], 'rung': p['rung']}
                        for p in self.plugins()],
            'events': self._buffer.status(),
        }

    def redact(self, text):
        return self._broker.scrub(text)

    def refresh_secrets(self):
        self._broker.refresh()

    def close(self):
        """close(): flush (solo: nothing in flight), then warn on profile
        instance keys that matched no registered instance - a typo'd key
        silently configuring nothing is the worst outcome for a
        secrets-and-policy file (design station.md 11)."""
        if self._closed:
            return
        with self._lock:
            registered = set(self._registry.keys())
        for name in self._profile['sdk'].keys():
            if name not in registered:
                self._emit({
                    't': _now_ms(), 'kind': 'station',
                    'meta': {'warn': 'profile plugin key "' + name +
                             '" matched no registered plugin'},
                })
        self._closed = True
        if Station._ambient is self:
            Station.reset()

    def _emit(self, ev):
        self._buffer.emit(ev)
