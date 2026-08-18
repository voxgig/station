// RUN: make test          (exports the env vars the env-hit cases need)
// RUN-SOME: dart run test/run.dart <case-name-substring>
//
// The station test harness: unit suites (test/station.dart) plus the
// shared conformance corpus (spec/station.json, test/conform.dart)
// through the sibling voxgig/omni checkout's Dart runner.
//
// No third-party test framework: a failing check throws, the harness
// counts it. This keeps `make test` dependency-free - the same
// discipline as the omni and generated-SDK dart suites.

import 'dart:async';
import 'dart:io';

import 'conform.dart';
import 'station.dart';

String? ONLY;
int passcount = 0;
int failcount = 0;

final List<MapEntry<String, FutureOr<void> Function()>> CASES = [];

void addcase(String name, FutureOr<void> Function() body) {
  CASES.add(MapEntry(name, body));
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    ONLY = args[0];
  }

  conformCases(addcase);
  stationCases(addcase);

  for (final entry in CASES) {
    if (null != ONLY && !entry.key.contains(ONLY!)) {
      continue;
    }
    try {
      await entry.value();
      passcount++;
      print('ok   - ${entry.key}');
    } catch (err) {
      failcount++;
      print('FAIL - ${entry.key}');
      print('$err');
    }
  }

  print('\n$passcount passed, $failcount failed');
  exit(0 == failcount ? 0 : 1);
}
