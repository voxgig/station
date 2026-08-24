// station.json lookup and profile resolution (design station.md 3.5).
//
// A port of typescript/src/profile.ts, which is canonical. Config values
// are plain string-keyed maps (jsonDecode output, or whatever the caller
// passed to open/new as `config`).

import 'dart:convert';
import 'dart:io';

import 'descriptor.dart';
import 'error.dart';
import 'secrets.dart';

// station.json lookup: cwd upward to the repo root, then
// ~/.voxgig/station.json (design station.md 3.5). A repo root is where
// .git lives; with no repo the walk stops at the filesystem root.
String? findConfigFile([String? from]) {
  var dir = Directory(from ?? Directory.current.path).absolute.path;
  for (;;) {
    final candidate = dir + Platform.pathSeparator + 'station.json';
    if (File(candidate).existsSync()) {
      return candidate;
    }
    final atRepoRoot =
        FileSystemEntity.typeSync(dir + Platform.pathSeparator + '.git') !=
            FileSystemEntityType.notFound;
    final parent = Directory(dir).parent.path;
    if (atRepoRoot || parent == dir) {
      break;
    }
    dir = parent;
  }

  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  if ('' != home) {
    final candidate = [home, '.voxgig', 'station.json']
        .join(Platform.pathSeparator);
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

dynamic loadConfig([String? from]) {
  final file = findConfigFile(from);
  if (null == file) {
    return null;
  }
  final text = File(file).readAsStringSync();
  // A file that is not JSON is a config error, not a raw FormatException
  // escaping open(): the reader found station.json and could not use it,
  // which is exactly what station_config_invalid exists to say.
  try {
    return jsonDecode(text);
  } catch (err) {
    throw StationError(
        'station_config_invalid',
        'station.json at ' +
            file +
            ' is not valid JSON: ' +
            (err is FormatException ? err.message : err.toString()));
  }
}

// Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
// else 'default' (design station.md 3.5 - env vars rank above
// station.json but below open() opts; profile NAME selection follows the
// same order with open() opts winning).
String selectProfile([dynamic optProfile]) {
  if (optProfile is String && '' != optProfile) {
    return optProfile;
  }
  final env = Platform.environment['VOXGIG_STATION_PROFILE'];
  if (null != env && '' != env) {
    return env;
  }
  return 'default';
}

dynamic _mget(dynamic m, String k) => m is Map ? m[k] : null;

Map<String, dynamic> _mmap(dynamic v) {
  final out = <String, dynamic>{};
  if (v is Map) {
    v.forEach((k, x) => out[k.toString()] = x);
  }
  return out;
}

List<dynamic>? _providersOf(dynamic profile) {
  final providers = _mget(_mget(profile, 'secrets'), 'providers');
  return providers is List ? providers : null;
}

// The one block key carrying the timing rule: applied AFTER the merge,
// never before (design 3.3, 4.2).
const List<String> MERGE_SENSITIVE = ['active'];

// The block defaults, allocated FRESH per application so no two
// instances ever share one `feature` map. `active` is a real JSON
// boolean - the corpus compares the serialized value.
Map<String, dynamic> _blockDefaults() => <String, dynamic>{
      'active': true,
      'feature': <String, dynamic>{},
    };

// The api half of a ref is the substring before the first `$`, and an
// untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
// point: under the old free-form identity which api an instance used
// was itself a merged value, so a port that got the phasing wrong
// silently picked another api's defaults.
String refapi(dynamic ref) {
  final s = (ref ?? '').toString();
  final at = s.indexOf(r'$');
  return -1 == at ? s : s.substring(0, at);
}

// Shallow merge, per key, left to right - each source over the one
// before it. An overlay's `policy` REPLACES the base's entirely rather
// than merging `hosts` into it; an allowlist that widens because two
// precedence levels merged is the failure this rule prevents.
Map<String, dynamic> _shallow(List<dynamic> sources) {
  final out = <String, dynamic>{};
  for (final src in sources) {
    if (src is Map) {
      src.forEach((k, v) => out[k.toString()] = v);
    }
  }
  return out;
}

// Sorted union of the keys of every map argument (non-maps skipped).
List<String> _mergedKeys(List<dynamic> maps) {
  final keys = <String>{};
  for (final m in maps) {
    if (m is Map) {
      for (final k in m.keys) {
        keys.add(k.toString());
      }
    }
  }
  return keys.toList()..sort();
}

// Merge the base profile ('default') with the selected overlay.
//
// Design 3.3's total order for the two block levels, lowest first:
//
//   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
//
// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
// LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
// namespace, then put instance over api" - that lets every instance
// value beat every api value, so a production `api.stripe.policy` would
// fail to override a default profile's `sdk.stripe$test.policy`,
// silently keeping the wider allowlist in production.
//
// `secrets.providers` replaces wholesale, never merges (3.5, 5.2):
// chain order decides which store wins, so a positional merge would be
// actively dangerous.
//
// Returns { name, providers, api, sdk } as a plain map (the corpus
// shape - the `instance` section pins it).
Map<String, dynamic> resolveProfile(dynamic config, String profileName) {
  final profiles = _mmap(_mget(config, 'profiles'));
  final base = _mmap(profiles['default']);
  final overlay =
      'default' == profileName ? <String, dynamic>{} : _mmap(profiles[profileName]);

  final providers = _providersOf(overlay) ??
      _providersOf(base) ??
      [
        {'kind': 'env'}
      ];

  final baseApi = _mmap(base['api']);
  final overApi = _mmap(overlay['api']);
  final baseSdk = _mmap(base['sdk']);
  final overSdk = _mmap(overlay['sdk']);

  // The api-level defaults in effect for this profile. A REPORT, not an
  // input to the instance merge below.
  final api = <String, dynamic>{};
  for (final slug in _mergedKeys([baseApi, overApi])) {
    api[slug] = _shallow([baseApi[slug], overApi[slug]]);
  }

  // An api block declares no instance of its own (3.1), so the ref set
  // comes from the two `sdk` maps alone.
  final sdk = <String, dynamic>{};
  for (final ref in _mergedKeys([baseSdk, overSdk])) {
    final a = refapi(ref);
    final merged =
        _shallow([baseApi[a], baseSdk[ref], overApi[a], overSdk[ref]]);

    // Defaults are applied ONCE, to the fully merged instance. Had the
    // overlay block carried a synthesized `active` into the merge, a
    // one-key environment override would silently re-enable an
    // integration the base declared inactive. Key MEMBERSHIP, not
    // truthiness: an explicit false or {} survives.
    _blockDefaults().forEach((k, v) {
      if (!merged.containsKey(k)) {
        merged[k] = v;
      }
    });

    sdk[ref] = merged;
  }

  _checksecrets(sdk, profileName);

  return <String, dynamic>{
    'name': profileName,
    'providers': providers,
    'api': api,
    'sdk': sdk,
  };
}

// A configured secret name sekreto would reject is caught at profile
// load, not first request (14 station_secret_name) - and then the
// DERIVED names are checked for uniqueness, because envtoken is lossy:
// it collapses any run of non-alphanumerics to `_`, so `stripe$test`
// and an untagged instance of a `stripe-test` api both derive
// `stripe_test.apikey` and would silently share one credential.
//
// Two instances that EXPLICITLY name one secret are not a collision -
// that is the shared-key case the api-level `secret` exists for.
void _checksecrets(Map<String, dynamic> sdk, String profileName) {
  final refs = sdk.keys.toList()..sort();

  for (final ref in refs) {
    final name = _mget(sdk[ref], 'secret');
    if (null != name && !validname(name)) {
      throw StationError(
          'station_secret_name',
          'profile "' +
              profileName +
              '" sdk "' +
              ref +
              '": secret name rejected by sekreto: ' +
              jsonEncode(name));
    }
  }

  final seen = <String, (String, bool)>{};
  for (final ref in refs) {
    final written = _mget(sdk[ref], 'secret');
    final derived = null == written || '' == written;
    final name = derived ? secretnameDefault(ref) : written.toString();

    final prior = seen[name];
    if (null != prior && (derived || prior.$2)) {
      throw StationError(
          'station_secret_collision',
          'profile "' +
              profileName +
              '": instances "' +
              prior.$1 +
              '" and "' +
              ref +
              '" both resolve to secret name "' +
              name +
              '", so they would share one credential; name it explicitly ' +
              'on each, or at the api level to share it deliberately (5.1)');
    }
    if (null == prior) {
      seen[name] = (ref, derived);
    }
  }
}
