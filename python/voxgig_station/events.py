# The solo event surface (design station.md 6): a bounded ring buffer plus
# a live tap with serialized callbacks. Events never fail an operation;
# overflow drops oldest and the drop count is visible in status().
#
# A port of typescript/src/events.ts, which is canonical. Synchronized
# with one lock: all public station operations are safe to call from any
# thread (design station.md 10.2), and CPython list ops alone do not
# guarantee the ring/drop-count invariant.

import threading


class EventBuffer:
    def __init__(self, max_events=None):
        self._ring = []
        self._max = 1000 if max_events is None else max_events
        self._drops = 0
        self._taps = []
        self._lock = threading.Lock()

    def emit(self, ev):
        with self._lock:
            self._ring.append(ev)
            if len(self._ring) > self._max:
                self._ring.pop(0)
                self._drops += 1
            taps = list(self._taps)

        # Serialized, and a throwing tap must not fail the operation that
        # emitted the event.
        for fn in taps:
            try:
                fn(ev)
            except Exception:
                pass

    def events(self):
        with self._lock:
            return list(self._ring)

    def tap(self, fn):
        with self._lock:
            self._taps.append(fn)

        def untap():
            with self._lock:
                if fn in self._taps:
                    self._taps.remove(fn)

        return untap

    def status(self):
        with self._lock:
            return {'buffered': len(self._ring), 'dropped': self._drops}
