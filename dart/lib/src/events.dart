// The solo event surface (design station.md 6): a bounded ring buffer
// plus a live tap with serialized callbacks. Events never fail an
// operation; overflow drops oldest and the drop count is visible in
// status().
//
// A port of typescript/src/events.ts, which is canonical. Events are
// plain string-keyed maps (the StationEvent v1 shape of station.md 6):
// { t, plugin?, corr?, kind, op?, http?, err?, meta? }.

typedef TapFn = void Function(Map<String, dynamic> ev);

class EventBuffer {
  final List<Map<String, dynamic>> _ring = [];
  final int _max;
  int _drops = 0;
  final List<TapFn> _taps = [];

  EventBuffer([int? max]) : _max = max ?? 1000;

  void emit(Map<String, dynamic> ev) {
    _ring.add(ev);
    if (_ring.length > _max) {
      _ring.removeAt(0);
      _drops++;
    }
    // Serialized, and a throwing tap must not fail the operation that
    // emitted the event.
    for (final fn in List<TapFn>.from(_taps)) {
      try {
        fn(ev);
      } catch (_e) {
        // A tap failure is the tap's problem, never the operation's.
      }
    }
  }

  List<Map<String, dynamic>> events() => List<Map<String, dynamic>>.from(_ring);

  void Function() tap(TapFn fn) {
    _taps.add(fn);
    return () {
      _taps.remove(fn);
    };
  }

  Map<String, dynamic> status() => <String, dynamic>{
        'buffered': _ring.length,
        'dropped': _drops,
      };
}
