// The secret broker (design station.md 5): a resolver names a secret,
// station places the value where the application cannot reach it. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical - with the one
// honest divergence the tier table (station.md 2.2) requires: **no Dart
// sekreto port exists, so this library is env-only for secrets and says
// so.** It reads the process environment directly under the sekreto env
// key of the secret name - the one provider that needs no library - and
// refuses, rather than pretends, when a chain names any other store:
//
//   - an `env` provider that does not hold the name is a MISS and the
//     chain carries on (station_secret_no_value when every store missed);
//   - any non-env provider kind is a store this port CANNOT ANSWER from,
//     which per station.md 5.2 is an error (station_secret_error), never
//     a fall-through - skipping it would quietly reach for a weaker
//     store.
//
// The permanent fix is a sekreto Dart port, contributed to sekreto
// (station.md 18); until then, attached-mode proxy-side resolution is the
// path to vaults for Dart apps, and this broker covers exactly solo.
//
// The two sekreto name rules this port needs are restated here EXACTLY
// once (sekreto typescript/src/Sekreto.ts validname/envkey - the corpus
// `secretname` section pins the round-trip): a name is dot-separated
// segments of [a-z0-9_]+, and its env key joins the segments with '_'
// and upper-cases.

import 'dart:io';

import 'error.dart';

final RegExp _namepart = RegExp(r'^[a-z0-9_]+$');

String placeholderFor(dynamic slug) {
  return '[station:' + (slug ?? '').toString() + ']';
}

// sekreto's validname: dot-separated lowercase segments.
bool validname(dynamic name) {
  if (name is! String || '' == name) {
    return false;
  }
  return name.split('.').every((seg) => _namepart.hasMatch(seg));
}

// sekreto's envkey: 'voxgig_solardemo.apikey' -> 'VOXGIG_SOLARDEMO_APIKEY'.
String envkey(dynamic name, [String prefix = '']) {
  return prefix +
      (name ?? '').toString().split('.').join('_').toUpperCase();
}

class SecretBroker {
  final List<dynamic> _providers;

  // Values hoisted by adopt() from a resident options apikey (design
  // station.md 3.1).
  final Map<String, String> _overrides = {};

  // One resolved value per plugin.
  final Map<String, String> _cache = {};

  // Every value this broker ever held, for the exact-value scrub.
  final List<String> _held = [];

  SecretBroker(List<dynamic>? providers)
      : _providers = (null == providers || providers.isEmpty)
            ? [
                {'kind': 'env'}
              ]
            : providers;

  void hoist(String slug, String value) {
    _overrides[slug] = value;
    _held.add(value);
  }

  // Resolve the value for a plugin's secret name against the profile's
  // provider chain. Throws StationError - misses and store errors keep
  // sekreto's distinction (design station.md 5.2): a miss is
  // station_secret_no_value, a store that could not answer is
  // station_secret_error, and never a retry against a weaker store. The
  // caller (the transport middleware) catches and returns the error as
  // a value, the generated pipeline's iserr convention.
  String value(String slug, String name) {
    final override = _overrides[slug];
    if (null != override) {
      return override;
    }

    final cached = _cache[slug];
    if (null != cached) {
      return cached;
    }

    if (!validname(name)) {
      throw StationError('station_secret_error',
          'invalid secret name (sekreto name rules): "' + name + '"');
    }

    for (final p in _providers) {
      final kind = p is Map ? p['kind'] : null;
      if ('env' == kind) {
        final prefix =
            (p is Map && p['prefix'] is String) ? p['prefix'] as String : '';
        final found = Platform.environment[envkey(name, prefix)];
        if (null != found) {
          _cache[slug] = found;
          _held.add(found);
          return found;
        }
        // A store that does not hold the secret is a miss and the chain
        // carries on.
      } else {
        throw StationError(
            'station_secret_error',
            'provider kind "' +
                kind.toString() +
                '" is unavailable: no dart sekreto port exists, so solo ' +
                'mode is env-only (station.md 2.2); the chain stops here ' +
                'rather than falling through to a weaker store ' +
                '(station.md 5.2)');
      }
    }

    throw StationError('station_secret_no_value',
        'no store had "' + name + '" for plugin "' + slug + '"');
  }

  // The provider kinds this env-only port cannot serve, for the says-so
  // warning at construction (design station.md 2.2).
  List<String> unsupportedKinds() {
    final out = <String>[];
    for (final p in _providers) {
      final kind = (p is Map ? p['kind'] : null).toString();
      if ('env' != kind && !out.contains(kind)) {
        out.add(kind);
      }
    }
    return out;
  }

  // Exact-value scrub, deliberately WITHOUT sekreto's four-character
  // readability floor (design station.md 7 as revised): on boundaries
  // where the promise is absolute, every held value is scrubbed whatever
  // its length. There is no sekreto instance underneath this env-only
  // broker, so the held list is the complete set of values ever resolved
  // or hoisted - nothing more to delegate to.
  String scrub(dynamic text) {
    var out = (text ?? '').toString();
    for (final value in _held) {
      if ('' != value) {
        out = out.split(value).join('[redacted]');
      }
    }
    return out;
  }

  // Drop the cache so the next resolve asks the stores again (rotation
  // support, design station.md 5.3). Hoisted overrides survive, as in
  // the canonical broker.
  void refresh() {
    _cache.clear();
  }
}
