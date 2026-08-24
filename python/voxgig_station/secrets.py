# The secret broker (design station.md 5): sekreto resolves, station
# places. The broker holds resolved values privately - they never enter
# options, events, or captures; the SDK sees only the placeholder.
#
# A port of typescript/src/secrets.ts, which is canonical. Synchronous
# throughout - the py SDK pipeline is synchronous, and so is sekreto's
# python port.

import threading

from voxgig_sekreto import Sekreto, SekretoError

from .error import StationError


def placeholder_for(name):
    """Keyed by INSTANCE (design station.md 7.2). Two live instances of
    one api must have distinct placeholders or the injection seam cannot
    tell which credential a header wants. For an untagged instance this
    is the api slug, so the single-instance case is unchanged."""
    return '[station:' + name + ']'


class SecretBroker:
    def __init__(self, providers):
        self._sekreto = Sekreto({'providers': providers})
        # Values hoisted by adopt() from resident options.apikey
        # (design station.md 3.1).
        self._overrides = {}
        self._cache = {}
        # Every value this broker ever held, for the exact-value scrub.
        self._held = []
        self._lock = threading.Lock()

    def hoist(self, instance, value):
        with self._lock:
            self._overrides[instance] = value
            self._held.append(value)

    def value(self, instance, name):
        """Resolve the value for an instance's secret name. Misses and
        store errors keep sekreto's distinction (design station.md 5.2):
        a miss is station_secret_no_value, a store that could not answer
        is station_secret_error with sekreto's message intact - and never
        a retry against a weaker store (sekreto owns the chain).

        OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
        SECRET NAME (design 5.3). A hoisted credential belongs to the one
        instance it was resident in, but a resolved VALUE belongs to the
        name it was resolved for - so several instances sharing one
        api-level `secret` cost one lookup rather than one each, and
        every client an auto-tagged create() produces shares the declared
        instance's entry instead of re-resolving per request. Keying the
        cache by instance instead is the defect this replaces: at 26
        instances over 20 apis it turns one store round-trip into 26."""
        with self._lock:
            override = self._overrides.get(instance)
            if override is not None:
                return override

            cached = self._cache.get(name)
            if cached is not None:
                return cached

        try:
            value = self._sekreto.get(name)
        except SekretoError as e:
            if 'unknown secret' in str(e):
                raise StationError(
                    'station_secret_no_value',
                    'no store had "' + name + '" for plugin "' + instance + '"')
            raise StationError('station_secret_error', str(e))
        except Exception as e:
            raise StationError('station_secret_error', str(e))

        with self._lock:
            self._cache[name] = value
            self._held.append(value)
        return value

    def scrub(self, text):
        """Exact-value scrub, deliberately WITHOUT sekreto's four-character
        readability floor (design station.md 7 as revised): on boundaries
        where the promise is absolute, every held value is scrubbed
        whatever its length. sekreto's own redact() runs too, covering
        values resolved by the underlying instance that station never
        held."""
        out = self._sekreto.redact(text)
        with self._lock:
            held = list(self._held)
        for value in held:
            if '' != value:
                out = '[redacted]'.join(out.split(value))
        return out

    def refresh(self):
        """Drop caches so the next resolve asks the stores again (rotation
        support rides on sekreto's refresh, design station.md 5.3)."""
        with self._lock:
            self._cache.clear()
        refresh = getattr(self._sekreto, 'refresh', None)
        if callable(refresh):
            refresh()
