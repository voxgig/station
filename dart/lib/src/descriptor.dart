// Descriptor v1 (design station.md 4): a view over the SDK's embedded
// config, normalized - never a second model. Plus the canonical
// serializer and the envtoken/secretname grammar.
//
// A port of typescript/src/descriptor.ts, which is canonical.

import 'dart:convert';

// The ONLY way to build an env-var token in station, mirroring sdkgen's
// packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
// `secretname` corpus section pins the round-trip against sekreto's
// envkey() and sdkgen's envName() - the one place three grammars meet.
String envtoken(dynamic name) {
  return (name ?? '')
      .toString()
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}

// The default sekreto name for a plugin (design station.md 5.1):
// envtoken(slug) lowercased, plus '.apikey'. sekreto's envkey() then
// yields exactly the env var the SDK's README documents:
// gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
String secretnameDefault(dynamic slug) {
  return envtoken(slug).toLowerCase() + '.apikey';
}

// Best-effort slug from a camel name, for SDKs whose embedded config
// predates main.slug (design station.md 4 legacy sentinels). The hyphen
// caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
// 'voxgig-solardemo' - callers surface a warning event when this path is
// taken.
String _legacySlug(dynamic name) {
  return (name ?? '').toString().toLowerCase();
}

// The normalizer's result: the descriptor (a plain string-keyed map, the
// shape the corpus pins) plus any legacy warnings.
class Normalized {
  final Map<String, dynamic> descriptor;
  final List<String> warnings;
  Normalized(this.descriptor, this.warnings);
}

dynamic _mget(dynamic m, String k) => m is Map ? m[k] : null;

// Normalize a generated SDK's embedded config into descriptor v1
// (design station.md 4). The config is the one every SDK carries
// (Config.main / .feature / .options / .entity); the descriptor is a
// VIEW over it.
Normalized normalizeDescriptor(dynamic config, [dynamic activeFeatures]) {
  final warnings = <String>[];
  final main = _mget(config, 'main') ?? {};
  final options = _mget(config, 'options') ?? {};

  final name = (_mget(main, 'name') ?? '').toString();
  var slug = _mget(main, 'slug');
  if (null == slug || '' == slug) {
    slug = _legacySlug(name);
    warnings.add('descriptor: legacy config has no main.slug; derived "' +
        slug.toString() +
        '" from the camel name - hyphens in the original name are lost');
  }
  slug = slug.toString();

  final version = null != _mget(main, 'version')
      ? _mget(main, 'version').toString()
      : '0.0.0';
  final target = null != _mget(main, 'target')
      ? _mget(main, 'target').toString()
      : 'unknown';

  final server = <Map<String, dynamic>>[];
  final svr = _mget(options, 'server') ?? {};
  if (svr is Map) {
    final skeys = svr.keys.map((k) => k.toString()).toList()..sort();
    for (final k in skeys) {
      server.add(<String, dynamic>{'name': k, 'value': svr[k].toString()});
    }
  }

  final authActive = null != _mget(options, 'auth');
  final auth = <String, dynamic>{
    'active': authActive,
    'prefix':
        authActive ? (_mget(_mget(options, 'auth'), 'prefix') ?? '').toString() : '',
    'secretname': secretnameDefault(slug),
  };

  final entities = <String, dynamic>{};
  final entdefs = _mget(config, 'entity') ?? {};
  if (entdefs is Map) {
    final enames = entdefs.keys.map((k) => k.toString()).toList()..sort();
    for (final ename in enames) {
      final e = entdefs[ename] ?? {};
      final fields = <String, dynamic>{};
      final flist = _mget(e, 'fields');
      if (flist is List) {
        for (final f in flist) {
          if (f is Map && null != f['name']) {
            var kind = f['kind'];
            if (null == kind || '' == kind) {
              kind = f['type'];
            }
            fields[f['name'].toString()] = <String, dynamic>{
              'kind': (kind ?? '').toString(),
            };
          }
        }
      }
      final ops = <String, dynamic>{};
      final opdefs = _mget(e, 'op') ?? {};
      if (opdefs is Map) {
        final opnames = opdefs.keys.map((k) => k.toString()).toList()..sort();
        for (final opname in opnames) {
          final op = opdefs[opname] ?? {};
          final points = <Map<String, dynamic>>[];
          final plist = _mget(op, 'points');
          if (plist is List) {
            for (final p in plist) {
              if (p is! Map) {
                continue;
              }
              final params = <String>[];
              final parts = p['parts'];
              if (parts is List) {
                for (final s in parts) {
                  if (s is String && s.startsWith(':')) {
                    params.add(s.substring(1));
                  }
                }
              }
              final point = <String, dynamic>{
                'method': (p['method'] ?? '').toString(),
                'path': (p['orig'] ?? p['path'] ?? '').toString(),
                'params': params,
              };
              if (null != p['select']) {
                point['select'] = p['select'];
              }
              points.add(point);
            }
          }
          ops[opname] = <String, dynamic>{'points': points};
        }
      }
      entities[ename] = <String, dynamic>{'fields': fields, 'ops': ops};
    }
  }

  final features = <Map<String, dynamic>>[];
  final fdefs = _mget(config, 'feature') ?? {};
  final factive = activeFeatures is Map ? activeFeatures : {};
  if (fdefs is Map) {
    final fnames = fdefs.keys.map((k) => k.toString()).toList()..sort();
    for (final fname in fnames) {
      features.add(<String, dynamic>{
        'name': fname,
        'active': true == _mget(factive[fname], 'active'),
      });
    }
  }

  final descriptor = <String, dynamic>{
    'station': 1,
    'name': name,
    'slug': slug,
    'envtoken': envtoken(slug),
    'version': version,
    'target': target,
    'base': (_mget(options, 'base') ?? '').toString(),
    'server': server,
    'auth': auth,
    'entities': entities,
    'features': features,
  };

  return Normalized(descriptor, warnings);
}

// Canonical serialization (design station.md 4): UTF-8, object keys
// sorted bytewise, no insignificant whitespace, minimal JSON escaping.
// The proxy dedupes registrations by a hash of this, so every language
// must produce identical bytes - the `canonical` corpus section carries
// the adversarial cases.
String canonicalSerialize(dynamic value) {
  if (null == value) {
    return 'null';
  }
  if (value is bool) {
    return value ? 'true' : 'false';
  }
  if (value is int) {
    return value.toString();
  }
  if (value is num) {
    // A whole double serializes as the integer it is, matching the
    // reference JSON.stringify - the descriptor's numeric fields are
    // integers by definition.
    final d = value.toDouble();
    if (d.isFinite && d == d.truncateToDouble() && d.abs() < 9007199254740992.0) {
      return d.truncate().toString();
    }
    return value.toString();
  }
  if (value is String) {
    return _jsonString(value);
  }
  if (value is List) {
    return '[' + value.map(canonicalSerialize).join(',') + ']';
  }
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList();
    keys.sort(_bytewise);
    return '{' +
        keys
            .map((k) => _jsonString(k) + ':' + canonicalSerialize(value[k]))
            .join(',') +
        '}';
  }
  return 'null';
}

// Bytewise sort: compare UTF-8 byte sequences, not UTF-16 code units.
int _bytewise(String a, String b) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  final n = ab.length < bb.length ? ab.length : bb.length;
  for (var i = 0; i < n; i++) {
    if (ab[i] != bb[i]) {
      return ab[i] - bb[i];
    }
  }
  return ab.length - bb.length;
}

// Minimal JSON string escaping, matching the reference JSON.stringify:
// quote and backslash, the short escapes, \u00xx for other control
// characters; everything else (non-ASCII included) passes through raw.
String _jsonString(String s) {
  final out = StringBuffer('"');
  for (final unit in s.codeUnits) {
    switch (unit) {
      case 0x22:
        out.write(r'\"');
        break;
      case 0x5c:
        out.write(r'\\');
        break;
      case 0x08:
        out.write(r'\b');
        break;
      case 0x09:
        out.write(r'\t');
        break;
      case 0x0a:
        out.write(r'\n');
        break;
      case 0x0c:
        out.write(r'\f');
        break;
      case 0x0d:
        out.write(r'\r');
        break;
      default:
        if (unit < 0x20) {
          out.write('\\u' + unit.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.write('"');
  return out.toString();
}
