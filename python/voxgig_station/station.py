# The station library core, solo mode (design D1): fully functional
# in-process with no other component running. The proxy (D2) is a
# deferred amplifier - `require` therefore fails on the operation path
# (design station.md 2.1/14), and `auto` degrades to solo with one
# warning event.
#
# A port of typescript/src/Station.ts, which is canonical. Synchronous
# throughout: the py SDK pipeline is synchronous and its transport seam
# returns (response, err) tuples, so the middleware does too.

import json
import threading
import time
from urllib.parse import urlparse

from .descriptor import canonical_serialize, normalize_descriptor
from .error import StationError
from .events import EventBuffer
from .profile import load_config, resolve_profile, select_profile
from .secrets import SecretBroker, placeholder_for


def _now_ms():
    return int(time.time() * 1000)


def _first_non_empty(*vals):
    for v in vals:
        if v is not None and '' != v:
            return v
    return None


class Station:
    _ambient = None
    _ambient_opts = None
    _ambient_lock = threading.Lock()

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

        self._profile = resolve_profile(
            config, select_profile(self._opts.get('profile')))
        self._broker = SecretBroker(self._profile['providers'])
        self._buffer = EventBuffer()
        self._registry = {}
        self._secret_override = {}
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

    def options(self, extra=None):
        """Inverted binding (design station.md 3.1): build the plain
        options map a generated constructor already accepts - the handle,
        the activation entry, and the caller's own opts."""
        extra = extra or {}
        calleropts = {k: v for k, v in extra.items() if 'extend' != k}
        fmap = dict(extra.get('feature') or {})
        entry = dict(fmap.get('station') or {})
        entry.update({
            'active': True,
            'station': self._handle(),
            'calleropts': calleropts,
        })
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
        SDK class still fails _register's slug check (10.2)."""
        with self._lock:
            for entry in self._registry.values():
                if entry['client'] is client:
                    return entry
        return None

    def _register(self, client, config, options, _calleropts, fopts=None):
        descriptor, warnings = normalize_descriptor(
            config, (options or {}).get('feature'))
        slug = descriptor['slug']

        with self._lock:
            if slug in self._registry:
                raise StationError(
                    'station_bound_twice',
                    'plugin "' + slug + '" is already registered; binding one '
                    'client twice is an error (10.2)')

            profile_plugin = self._profile['sdk'].get(slug)
            # Secret name precedence: the feature option (in-code, design
            # station.md 9 config.options.secret) beats the profile, which
            # beats the descriptor default.
            secretname = _first_non_empty(
                (fopts or {}).get('secret'),
                (profile_plugin or {}).get('secret'),
            ) or descriptor['auth']['secretname']
            fsecret = (fopts or {}).get('secret')
            if fsecret is not None and '' != fsecret:
                self._secret_override[slug] = fsecret

            rung = 'R1' if descriptor['auth']['active'] else 'none'
            binding = {
                'plugin': slug,
                'placeholder': placeholder_for(slug)
                if descriptor['auth']['active'] else None,
                'secretname': secretname
                if descriptor['auth']['active'] else None,
                'rung': rung,
            }

            self._registry[slug] = {
                'slug': slug, 'descriptor': descriptor, 'rung': rung,
                'client': client, 'warnings': warnings,
            }

        for w in warnings:
            self._emit({'t': _now_ms(), 'kind': 'station', 'plugin': slug,
                        'meta': {'warn': w}})
        self._emit({
            't': _now_ms(), 'kind': 'construct', 'plugin': slug,
            'meta': {'name': descriptor['name'],
                     'version': descriptor['version'], 'rung': rung},
        })

        return binding, profile_plugin

    def _hoist(self, slug, value):
        self._broker.hoist(slug, value)
        self._emit({
            't': _now_ms(), 'kind': 'station', 'plugin': slug,
            'meta': {
                'warn': 'a resident credential was hoisted into the broker '
                        'and replaced by the placeholder; prefer configuring '
                        'the secret name and letting sekreto resolve it',
            },
        })

    # --- the transport middleware (design station.md 3.3, 5.3) ---

    def _transport(self, slug, inner, fctx, fullurl, fetchdef):
        """The wrap installed by the adapter. py transport contract: a
        (response, err) tuple, and features may also see raised
        exceptions - both shapes are preserved."""
        # Fail-closed means traffic (design station.md 2.1): with the
        # proxy deferred, `require` can never attach, so every operation
        # fails here - the operation path, never the constructor.
        if self._require_proxy:
            err = StationError('station_no_proxy',
                               'proxy: "require" is set and no proxy is attached')
            self._emit_err(slug, fctx, err)
            return None, err

        with self._lock:
            entry = self._registry.get(slug)
        placeholder = placeholder_for(slug)
        # Mock detection: the py SDK's public mode attribute
        # (design station.md 3.3 - never inject into mock transports).
        client = getattr(fctx, 'client', None)
        live = 'live' == getattr(client, 'mode', None)
        profile_plugin = self._profile['sdk'].get(slug) or {}

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
                    'of plugin "' + slug + '"')
                self._emit_err(slug, fctx, err)
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
            secretname = _first_non_empty(
                self._secret_override.get(slug),
                profile_plugin.get('secret'),
            ) or entry['descriptor']['auth']['secretname']

            try:
                value = self._broker.value(slug, secretname)
            except Exception as e:
                self._emit_err(slug, fctx, e)
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
            self._emit_http(slug, corr, fullurl, senddef, 0, started, 0)
            self._emit_err(slug, fctx, e)
            raise

        if err is not None:
            self._emit_http(slug, corr, fullurl, senddef, 0, started, 0)
            self._emit_err(slug, fctx, err)
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
        self._emit_http(slug, corr, fullurl, senddef, status, started, nbytes)

        return res, err

    def _emit_http(self, slug, corr, fullurl, fetchdef, status, started, nbytes):
        host = ''
        path = ''
        try:
            u = urlparse(fullurl)
            host = u.netloc
            path = u.path
        except Exception:
            path = fullurl
        ev = {
            't': started, 'kind': 'http', 'plugin': slug,
            'http': {
                'method': (fetchdef or {}).get('method') or 'GET',
                'host': host, 'path': path, 'status': status,
                'durationMs': _now_ms() - started, 'bytes': nbytes,
            },
        }
        if corr is not None:
            ev['corr'] = corr
        self._emit(ev)

    def _emit_err(self, slug, fctx, err):
        st = getattr(fctx, '_station', None) or {}
        ev = {
            't': _now_ms(), 'kind': 'error', 'plugin': slug,
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

    def _op_event(self, slug, ctx, outcome):
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
            't': _now_ms(), 'kind': 'op', 'plugin': slug,
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
        with self._lock:
            return [{
                'slug': e['slug'],
                'descriptor': e['descriptor'],
                'rung': e['rung'],
                'warnings': list(e['warnings']),
            } for e in self._registry.values()]

    def descriptor_of(self, slug):
        with self._lock:
            entry = self._registry.get(slug)
            known = list(self._registry.keys())
        if entry is None:
            raise StationError(
                'station_no_plugin',
                'unknown plugin "' + slug + '"; known: [' +
                ', '.join(known) + ']')
        return entry['descriptor']

    def canonical_descriptor(self, slug):
        return canonical_serialize(self.descriptor_of(slug))

    def events(self):
        return self._buffer.events()

    def tap(self, fn):
        return self._buffer.tap(fn)

    def status(self):
        return {
            'mode': 'solo',
            'profile': self._profile['name'],
            'plugins': [{'slug': p['slug'], 'rung': p['rung']}
                        for p in self.plugins()],
            'events': self._buffer.status(),
        }

    def redact(self, text):
        return self._broker.scrub(text)

    def refresh_secrets(self):
        self._broker.refresh()

    def close(self):
        """close(): flush (solo: nothing in flight), then warn on profile
        plugin keys that matched no registered plugin - a typo'd key
        silently configuring nothing is the worst outcome for a
        secrets-and-policy file (design station.md 11)."""
        if self._closed:
            return
        with self._lock:
            registered = set(self._registry.keys())
        for slug in self._profile['sdk'].keys():
            if slug not in registered:
                self._emit({
                    't': _now_ms(), 'kind': 'station',
                    'meta': {'warn': 'profile plugin key "' + slug +
                             '" matched no registered plugin'},
                })
        self._closed = True
        if Station._ambient is self:
            Station.reset()

    def _emit(self, ev):
        self._buffer.emit(ev)
