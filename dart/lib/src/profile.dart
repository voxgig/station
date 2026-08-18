// station.json lookup and profile resolution (design station.md 3.5).
//
// A port of typescript/src/profile.ts, which is canonical. Config values
// are plain string-keyed maps (jsonDecode output, or whatever the caller
// passed to open/new as `config`).

import 'dart:convert';
import 'dart:io';

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
  return jsonDecode(File(file).readAsStringSync());
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

// Merge the base profile ('default') with the selected overlay:
// deep-merge per plugin, EXCEPT secrets.providers which replaces
// wholesale (design station.md 3.5, 5.2 - chain order decides which
// store wins, so a positional merge would be actively dangerous). The
// `profile` corpus section pins this.
//
// Returns { name, providers, plugin } as a plain map (the corpus shape).
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

  final plugin = <String, dynamic>{};
  for (final src in [_mmap(base['plugin']), _mmap(overlay['plugin'])]) {
    src.forEach((slug, popts) {
      if (popts is Map) {
        final merged = _mmap(plugin[slug]);
        popts.forEach((k, v) => merged[k.toString()] = v);
        plugin[slug] = merged;
      }
    });
  }

  // A configured secret name sekreto would reject is caught at profile
  // load, not first request (design station.md 14 station_secret_name).
  final slugs = plugin.keys.toList()..sort();
  for (final slug in slugs) {
    final name = _mget(plugin[slug], 'secret');
    if (null != name && !validname(name)) {
      throw StationError(
          'station_secret_name',
          'profile "' +
              profileName +
              '" plugin "' +
              slug +
              '": secret name rejected by sekreto\'s name rules: "' +
              name.toString() +
              '"');
    }
  }

  return <String, dynamic>{
    'name': profileName,
    'providers': providers,
    'plugin': plugin,
  };
}
