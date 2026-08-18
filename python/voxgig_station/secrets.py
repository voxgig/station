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


def placeholder_for(slug):
    return '[station:' + slug + ']'


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

    def hoist(self, slug, value):
        with self._lock:
            self._overrides[slug] = value
            self._held.append(value)

    def value(self, slug, name):
        """Resolve the value for a plugin's secret name. Misses and store
        errors keep sekreto's distinction (design station.md 5.2): a miss
        is station_secret_no_value, a store that could not answer is
        station_secret_error with sekreto's message intact - and never a
        retry against a weaker store (sekreto owns the chain)."""
        with self._lock:
            override = self._overrides.get(slug)
            if override is not None:
                return override

            cached = self._cache.get(slug)
            if cached is not None:
                return cached

        try:
            value = self._sekreto.get(name)
        except SekretoError as e:
            if 'unknown secret' in str(e):
                raise StationError(
                    'station_secret_no_value',
                    'no store had "' + name + '" for plugin "' + slug + '"')
            raise StationError('station_secret_error', str(e))
        except Exception as e:
            raise StationError('station_secret_error', str(e))

        with self._lock:
            self._cache[slug] = value
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
