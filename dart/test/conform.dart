// The station conformance suite: the pure-contract half of the design's
// (station.md 13) corpus, from spec/station.json, through voxgig/omni -
// the same file every port runs. Sections that need live SDK machinery
// (inject, order, event correlation) live in the generated-SDK
// integration flow; the corpus carries what a port can prove with no SDK
// present.
//
// omni is a sibling checkout, not a published package (yet), so its Dart
// runner is imported by relative path - ../../omni, the layout every
// port's candidate list defaults to (imports are static in Dart, so the
// path cannot come from OMNI_HOME).

import 'dart:async';
import 'dart:io';

import '../../../omni/dart/lib/omni.dart';

import '../lib/voxgig_station.dart';

// Find the shared spec by walking up from the working directory.
String specfile() {
  var dir = Directory.current.absolute.path;
  for (var step = 0; step < 8; step++) {
    final cand = '$dir/spec/station.json';
    if (File(cand).existsSync()) {
      return cand;
    }
    final parent = Directory(dir).parent.path;
    if (parent == dir) {
      break;
    }
    dir = parent;
  }
  throw OmniError('station: spec not found: station.json');
}

// Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
// serializer sees what the spec means.
dynamic denull(dynamic v) {
  if (NULLMARK == v) {
    return null;
  }
  if (v is List) {
    return v.map(denull).toList();
  }
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, x) => out[k.toString()] = denull(x));
    return out;
  }
  return v;
}

dynamic SECRETNAME(List<dynamic> args) {
  final vin = args[0];
  final secretname = secretnameDefault(vin['slug']);
  return <String, dynamic>{
    'envtoken': envtoken(vin['slug']),
    'secretname': secretname,
    'envkey': envkey(secretname),
  };
}

dynamic PLACEHOLDER(List<dynamic> args) => placeholderFor(args[0]);

dynamic DESCRIPTOR(List<dynamic> args) {
  final vin = args[0];
  return normalizeDescriptor(vin['config'], vin['feature']).descriptor;
}

dynamic DESCRIPTORWARNINGS(List<dynamic> args) {
  final vin = args[0];
  return normalizeDescriptor(vin['config'], vin['feature']).warnings.length;
}

dynamic CANONICAL(List<dynamic> args) => canonicalSerialize(denull(args[0]));

dynamic PROFILE(List<dynamic> args) {
  final vin = args[0];
  return resolveProfile(denull(vin['config']), vin['profile'].toString());
}

dynamic ERRORS(List<dynamic> args) => isKnownCode(args[0]);

// Register the corpus sections with the shared harness (test/run.dart).
void conformCases(void Function(String, FutureOr<void> Function()) testcase) {
  final R = makeRunner(specfile()).runner('station');

  testcase('conform: secretname', () => R.runset(R.set('secretname'), SECRETNAME));
  testcase('conform: placeholder', () => R.runset(R.set('placeholder'), PLACEHOLDER));
  testcase('conform: descriptor', () => R.runset(R.set('descriptor'), DESCRIPTOR));
  testcase('conform: descriptorwarnings',
      () => R.runset(R.set('descriptorwarnings'), DESCRIPTORWARNINGS));
  testcase('conform: canonical', () => R.runset(R.set('canonical'), CANONICAL));
  testcase('conform: profile', () => R.runset(R.set('profile'), PROFILE));
  testcase('conform: errors', () => R.runset(R.set('errors'), ERRORS));
}
