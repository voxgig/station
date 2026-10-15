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

import 'dart:convert';
import 'dart:io';

import 'error.dart';

final RegExp _namepart = RegExp(r'^[a-z0-9_]+$');

String placeholderFor(dynamic slug) {
  return '[station:' + (slug ?? '').toString() + ']';
}

// A substituted URL plus its header copy.
class Substituted {
  final String url;
  final Map<String, dynamic> headers;
  Substituted(this.url, this.headers);
}

bool _unreserved(int byte) =>
    (0x41 <= byte && byte <= 0x5A) ||
    (0x61 <= byte && byte <= 0x7A) ||
    (0x30 <= byte && byte <= 0x39) ||
    0x2D == byte ||
    0x2E == byte ||
    0x5F == byte ||
    0x7E == byte;

// Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
String encodeQueryValue(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (_unreserved(byte)) {
      out.writeCharCode(byte);
    } else {
      out.write('%' + byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

int _hexValue(int unit) {
  if (0x30 <= unit && unit <= 0x39) {
    return unit - 0x30;
  }
  if (0x41 <= unit && unit <= 0x46) {
    return unit - 0x37;
  }
  if (0x61 <= unit && unit <= 0x66) {
    return unit - 0x57;
  }
  return -1;
}

int _matchAt(String text, int at, int end, String placeholder) {
  var i = at;
  for (final ch in placeholder.codeUnits) {
    if (i < end && text.codeUnitAt(i) == ch) {
      i++;
      continue;
    }
    if (i + 3 <= end && 0x25 == text.codeUnitAt(i)) {
      final hi = _hexValue(text.codeUnitAt(i + 1));
      final lo = _hexValue(text.codeUnitAt(i + 2));
      if (0 <= hi && 0 <= lo && ch == hi * 16 + lo) {
        i += 3;
        continue;
      }
    }
    return -1;
  }
  return i - at;
}

// The placeholder becomes the value in header values and in the URL query,
// where an SDK percent-encodes it (any hex case) and the value is encoded in
// turn. The path and fragment are never touched; the headers are a copy.
Substituted substitute(
    String url, dynamic headers, String placeholder, String value) {
  final out = <String, dynamic>{};
  if (headers is Map) {
    headers.forEach((k, v) => out[k.toString()] = v);
  }
  if ('' == placeholder) {
    return Substituted(url, out);
  }

  for (final h in out.keys.toList()) {
    final v = out[h];
    if (v is String && v.contains(placeholder)) {
      out[h] = v.split(placeholder).join(value);
    }
  }

  final q = url.indexOf('?');
  final hash = url.indexOf('#');
  if (-1 == q || (-1 != hash && hash < q)) {
    return Substituted(url, out);
  }
  final end = -1 == hash ? url.length : hash;
  final encoded = encodeQueryValue(value);
  final query = StringBuffer();
  var i = q + 1;
  while (i < end) {
    final n = _matchAt(url, i, end, placeholder);
    if (0 < n) {
      query.write(encoded);
      i += n;
    } else {
      query.write(url[i]);
      i++;
    }
  }
  return Substituted(
      url.substring(0, q + 1) + query.toString() + url.substring(end), out);
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
  // or hoisted - nothing more to delegate to. Every form is matched
  // against the original text and the union of the matches redacted, so no
  // replacement can hide another form.
  String scrub(dynamic text) {
    final source = (text ?? '').toString();
    final forms = <String>[];
    for (final value in _held) {
      if ('' != value) {
        forms.add(value);
        forms.add(encodeQueryValue(value));
      }
    }
    int reach(int at) {
      var end = at;
      for (final form in forms) {
        if (at + form.length > end && source.startsWith(form, at)) {
          end = at + form.length;
        }
      }
      return end;
    }

    final out = StringBuffer();
    var i = 0;
    while (i < source.length) {
      var stop = reach(i);
      if (stop == i) {
        out.write(source[i]);
        i++;
        continue;
      }
      for (var j = i + 1; j < stop; j++) {
        final end = reach(j);
        if (end > stop) {
          stop = end;
        }
      }
      out.write('[redacted]');
      i = stop;
    }
    return out.toString();
  }

  // Drop the cache so the next resolve asks the stores again (rotation
  // support, design station.md 5.3). Hoisted overrides survive, as in
  // the canonical broker.
  void refresh() {
    _cache.clear();
  }
}
