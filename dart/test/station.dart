// Focused unit tests for the contracts the JSON corpus cannot express
// (design station.md 13): the ambient instance, the event ring + tap,
// the env-only broker's hit/miss/refusal semantics, the profile lookup
// walk, and the adapter half - featureBinding, the wrap-position guard,
// copy-on-inject, mock skip, hosts policy - exercised against a minimal
// duck-typed stand-in for the generated SDK's client/utility/ctx
// surface (the full pipeline is exercised by the generated-SDK
// integration flow, st-dart-sdk).
//
// Env-dependent cases (a real environment hit) need the variables the
// Makefile's `test` target exports; run standalone they skip with a
// notice rather than fail.

import 'dart:async';
import 'dart:io';

import '../lib/voxgig_station.dart';

// --- a minimal duck-typed slice of the generated SDK surface ---

class FakeUtility {
  dynamic fetcher;
}

class FakeClient {
  String mode = 'live';
  List<dynamic> features = [];
  final Map<String, dynamic> track = {};
}

class FakeFeature {
  String name;
  Map<String, dynamic> options = {};
  FakeFeature(this.name);
}

class FakeOp {
  final String entity;
  final String name;
  FakeOp(this.entity, this.name);
}

class FakeResult {
  dynamic err;
  dynamic ok;
  FakeResult({this.err, this.ok});
}

class FakeCtx {
  dynamic client;
  dynamic utility;
  dynamic options;
  dynamic config;
  dynamic op;
  dynamic result;
  final Map<String, dynamic> out = {};
  FakeCtx({this.client, this.utility, this.options, this.config});
}

Map<String, dynamic> petsConfig() => <String, dynamic>{
      'main': {
        'name': 'GnarlyPets',
        'slug': 'gnarly-pets',
        'version': '0.0.1',
        'target': 'dart',
      },
      'options': {
        'base': 'http://localhost:8903',
        'auth': {'prefix': 'Bearer'},
        'entity': {'pet': {}},
      },
      'entity': {
        'pet': {
          'fields': [
            {'name': 'name', 'kind': 'String'}
          ],
          'op': {
            'load': {
              'points': [
                {
                  'method': 'GET',
                  'orig': '/api/pet/:pet_id',
                  'parts': ['api', 'pet', ':pet_id'],
                }
              ]
            }
          }
        }
      },
      'feature': {'test': {}},
    };

// Build a bindable fake ctx: one client, the station feature at the
// guard-correct position (first; no test feature), a mutable fetcher.
FakeCtx makeCtx({dynamic inner, Map<String, dynamic>? options}) {
  final client = FakeClient();
  client.features.add(FakeFeature('station'));
  final utility = FakeUtility();
  utility.fetcher = inner ??
      (dynamic fctx, dynamic url, dynamic def) async => <String, dynamic>{
            'status': 200,
            'statusText': 'OK',
            'headers': {'content-length': '2'},
            'body': '[]',
            'json': () => [],
          };
  return FakeCtx(
    client: client,
    utility: utility,
    options: options ??
        <String, dynamic>{
          'apikey': '',
          'base': 'http://localhost:8903',
          'feature': {
            'station': {'active': true}
          },
        },
    config: petsConfig(),
  );
}

FeatureBinding? bindCtx(Station st, FakeCtx ctx) {
  return featureBinding(ctx, {'station': st, 'calleropts': {}});
}

// --- assertion helpers (dependency-free, like the omni harness) ---

void check(bool cond, String msg) {
  if (!cond) {
    throw StateError('check failed: ' + msg);
  }
}

void eq(dynamic actual, dynamic expected, String msg) {
  if (actual != expected) {
    throw StateError(
        'eq failed: ' + msg + ': expected [$expected] got [$actual]');
  }
}

Future<void> expectCode(String code, FutureOr<void> Function() body) async {
  try {
    await body();
  } catch (e) {
    final c = e is StationError ? e.code : '';
    eq(c, code, 'error code');
    return;
  }
  throw StateError('expected StationError ' + code);
}

List<Map<String, dynamic>> ofKind(Station st, String kind) {
  return st.events().where((e) => kind == e['kind']).toList();
}

bool hasEnv(String name) => Platform.environment.containsKey(name);

// Register the unit cases with the shared harness (test/run.dart).
void stationCases(void Function(String, FutureOr<void> Function()) testcase) {
  // --- ambient instance (design station.md 10.2) ---

  testcase('open is idempotent; conflicting options are an error', () {
    Station.reset();
    check(null == Station.current(), 'no ambient before open');
    final st = Station.open({'config': null});
    check(identical(st, Station.open({'config': null})), 'idempotent');
    check(identical(st, Station.current()), 'current');
    return expectCode('station_open_conflict',
        () => Station.open({'config': null, 'profile': 'prod'}));
  });

  testcase('new stays isolated from the ambient instance', () {
    Station.reset();
    final ambient = Station.open({'config': null});
    final isolated = Station({'config': null});
    check(!identical(ambient, isolated), 'isolated');
    check(identical(ambient, Station.current()), 'ambient unchanged');
    Station.reset();
  });

  testcase('close is idempotent and drops the ambient slot', () {
    Station.reset();
    final st = Station.open({'config': null});
    check(false == st.closed, 'open');
    st.close();
    check(true == st.closed, 'closed');
    st.close();
    check(null == Station.current(), 'ambient dropped');
  });

  // --- construction events ---

  testcase('auto proxy degrades to solo with one warning event', () {
    final st = Station({'config': null});
    final events = st.events();
    check(events.isNotEmpty, 'warning emitted');
    eq(events[0]['kind'], 'station', 'kind');
    check(events[0]['meta']['warn'].toString().contains('running solo'),
        'warn names solo');
  });

  testcase('proxy off emits no degradation warning', () {
    final st = Station({'config': null, 'proxy': 'off'});
    eq(st.events().length, 0, 'no events');
  });

  testcase('env-only honesty: unsupported kinds are said at construction', () {
    final st = Station({
      'proxy': 'off',
      'config': {
        'station': 1,
        'profiles': {
          'default': {
            'secrets': {
              'providers': [
                {'kind': 'env'},
                {'kind': 'hashicorp'}
              ]
            }
          }
        }
      },
    });
    final events = st.events();
    eq(events.length, 1, 'one warning');
    final warn = events[0]['meta']['warn'].toString();
    check(warn.contains('no dart sekreto port'), 'says why');
    check(warn.contains('hashicorp'), 'names the kind');
  });

  testcase('close warns on profile plugin keys matching no plugin', () {
    final st = Station({
      'proxy': 'off',
      'config': {
        'station': 1,
        'profiles': {
          'default': {
            'sdk': {
              'typod': {'base': 'http://x'}
            }
          }
        }
      },
    });
    st.close();
    final events = st.events();
    eq(events.length, 1, 'one warning');
    final warn = events[0]['meta']['warn'].toString();
    check(warn.contains('typod'), 'names the key');
    check(warn.contains('matched no registered plugin'), 'says why');
  });

  // --- the event ring (design station.md 6) ---

  testcase('ring is bounded, drops oldest, and counts drops in status', () {
    final buf = EventBuffer(3);
    for (var n = 1; n <= 5; n++) {
      buf.emit({'n': n});
    }
    final events = buf.events();
    eq(events.length, 3, 'bounded');
    eq(events[0]['n'], 3, 'oldest dropped');
    eq(events[2]['n'], 5, 'newest kept');
    eq(buf.status()['buffered'], 3, 'buffered');
    eq(buf.status()['dropped'], 2, 'dropped');
  });

  testcase('tap sees events, unsubscribes, a throwing tap never fails emit',
      () {
    final st = Station({'config': null, 'proxy': 'off'});
    final seen = <Map<String, dynamic>>[];
    final untapRaise = st.tap((ev) => throw StateError('tap boom'));
    final untap = st.tap((ev) => seen.add(ev));

    st.emit({'t': 1, 'kind': 'station', 'meta': {'warn': 'w1'}});
    eq(seen.length, 1, 'tap saw the event');

    untap();
    untapRaise();
    st.emit({'t': 2, 'kind': 'station', 'meta': {'warn': 'w2'}});
    eq(seen.length, 1, 'unsubscribed');
    eq(st.status()['events']['buffered'], 2, 'both buffered');
  });

  testcase('status shape', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final status = st.status();
    eq(status['mode'], 'solo', 'mode');
    eq(status['profile'], 'default', 'profile');
    eq((status['plugins'] as List).length, 0, 'plugins');
    eq(status['events']['buffered'], 0, 'buffered');
    eq(status['events']['dropped'], 0, 'dropped');
  });

  // --- the env-only broker (design station.md 2.2, 5.2) ---

  testcase('env provider resolves the sekreto env key', () {
    if (!hasEnv('STATIONTEST_ONE_APIKEY')) {
      print('     (skipped: STATIONTEST_ONE_APIKEY not set - use make test)');
      return null;
    }
    final broker = SecretBroker([
      {'kind': 'env'}
    ]);
    eq(broker.value('stationtest-one', 'stationtest_one.apikey'),
        Platform.environment['STATIONTEST_ONE_APIKEY'], 'env hit');
    return null;
  });

  testcase('a miss is not an error: station_secret_no_value', () {
    final broker = SecretBroker([
      {'kind': 'env'}
    ]);
    return expectCode('station_secret_no_value',
        () => broker.value('p', 'stationtest_missing.apikey'));
  });

  testcase('a store this port cannot answer from errs, never falls through',
      () {
    final broker = SecretBroker([
      {'kind': 'env'},
      {'kind': 'dotenv', 'file': '.env'}
    ]);
    return expectCode('station_secret_error',
        () => broker.value('p', 'stationtest_chain.apikey'));
  });

  testcase('an env hit earlier in the chain never reaches the refusal', () {
    if (!hasEnv('STATIONTEST_FIRST_APIKEY')) {
      print('     (skipped: STATIONTEST_FIRST_APIKEY not set - use make test)');
      return null;
    }
    final broker = SecretBroker([
      {'kind': 'env'},
      {'kind': 'hashicorp'}
    ]);
    eq(broker.value('p', 'stationtest_first.apikey'),
        Platform.environment['STATIONTEST_FIRST_APIKEY'], 'hit');
    return null;
  });

  testcase('an invalid secret name is a station_secret_error', () {
    final broker = SecretBroker([
      {'kind': 'env'}
    ]);
    return expectCode(
        'station_secret_error', () => broker.value('p', 'Not A Name'));
  });

  testcase('hoisted values win over the chain', () {
    final broker = SecretBroker([
      {'kind': 'env'}
    ]);
    broker.hoist('solardemo', 'resident-key');
    eq(broker.value('solardemo', 'x.apikey'), 'resident-key', 'override');
  });

  testcase('scrub is exact-value with no length floor', () {
    final broker = SecretBroker(null);
    broker.hoist('a', 'k');
    broker.hoist('b', 'long-secret-value');
    final out = broker.scrub('got k and long-secret-value back');
    check(!out.contains('long-secret-value'), 'long value scrubbed');
    check(out.contains('[redacted]'), 'redaction marker');
    check(!out.contains(' k '), 'one-char value scrubbed');
  });

  testcase('redact runs the broker scrub through the station', () {
    final st = Station({'config': null, 'proxy': 'off'});
    st.hoist('solardemo', 'sekrit');
    check(!st.redact('a sekrit b').contains('sekrit'), 'scrubbed');
    // The hoist itself is a visible warning event, never a silent
    // downgrade.
    check(
        st.events().any((ev) =>
            'station' == ev['kind'] &&
            (ev['meta']?['warn'] ?? '').toString().contains('hoisted')),
        'hoist warned');
  });

  // --- profile lookup (design station.md 3.5) ---

  testcase('findConfigFile walks cwd upward', () {
    final base = Directory.systemTemp.createTempSync('station-test-');
    try {
      final nested = Directory(base.path + '/a/b')..createSync(recursive: true);
      File(base.path + '/station.json').writeAsStringSync('{ "station": 1 }');
      final found = findConfigFile(nested.path);
      eq(found, base.path + Platform.pathSeparator + 'station.json', 'found');
      final config = loadConfig(nested.path);
      eq(config['station'], 1, 'parsed');
    } finally {
      base.deleteSync(recursive: true);
    }
  });

  testcase('profile selection: option beats env beats default', () {
    eq(selectProfile('prod'), 'prod', 'option wins');
    if (!hasEnv('VOXGIG_STATION_PROFILE')) {
      eq(selectProfile(null), 'default', 'default');
      eq(selectProfile(''), 'default', 'empty option is no option');
    }
  });

  // --- canonical serializer edges beyond the corpus ---

  testcase('canonical serializer escapes control characters JSON-style', () {
    eq(canonicalSerialize('a' + String.fromCharCode(1) + 'b\nc'),
        '"a\\u0001b\\nc"', 'escapes');
  });

  testcase('envtoken trims and collapses non-alphanumerics', () {
    eq(envtoken('gnarly-pets'), 'GNARLY_PETS', 'hyphen');
    eq(envtoken('Weird--Name..2'), 'WEIRD_NAME_2', 'runs collapse');
    eq(envtoken(null), '', 'null');
  });

  testcase('normalize: auth-inactive config plans no credential', () {
    final normalized = normalizeDescriptor(<String, dynamic>{
      'main': {
        'name': 'Solardemo',
        'slug': 'solardemo',
        'version': '1.2.3',
        'target': 'dart',
      },
      'options': {'base': 'http://localhost:8901'},
      'entity': {},
      'feature': {},
    });
    eq(normalized.warnings.length, 0, 'no warnings');
    eq(normalized.descriptor['auth']['active'], false, 'inactive');
    eq(normalized.descriptor['auth']['secretname'], 'solardemo.apikey',
        'name still derived');
    eq(normalized.descriptor['target'], 'dart', 'target');
  });

  // --- the adapter half (design station.md 3) ---

  testcase('featureBinding without a station is an inert no-op', () {
    Station.reset();
    final ctx = makeCtx();
    check(null == featureBinding(ctx, {'active': true}), 'null binding');
    check(ctx.utility.fetcher is! StationTransport, 'transport untouched');
  });

  testcase('featureBinding registers, plants the placeholder, wraps', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    final binding = bindCtx(st, ctx);
    check(null != binding, 'bound');
    eq(binding!.slug, 'gnarly-pets', 'slug');
    eq(ctx.options['apikey'], '[station:gnarly-pets]', 'placeholder planted');
    check(ctx.utility.fetcher is StationTransport, 'transport wrapped');
    eq(ofKind(st, 'construct').length, 1, 'construct event');
    eq(st.plugins().length, 1, 'registered');
    eq(st.plugins()[0]['rung'], 'R1', 'rung');
    final d = st.descriptorOf('gnarly-pets');
    eq(d['envtoken'], 'GNARLY_PETS', 'envtoken');
    eq(d['auth']['secretname'], 'gnarly_pets.apikey', 'secretname');
    check(st.canonicalDescriptor('gnarly-pets').startsWith('{"auth":'),
        'canonical form sorted');
  });

  testcase('a second arrival on the same client is inert', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    check(null != bindCtx(st, ctx), 'first binds');
    check(null == bindCtx(st, ctx), 'second inert');
    eq(ofKind(st, 'construct').length, 1, 'one construct event');
  });

  testcase('binding a second client of the same SDK is station_bound_twice',
      () {
    final st = Station({'config': null, 'proxy': 'off'});
    check(null != bindCtx(st, makeCtx()), 'first binds');
    return expectCode('station_bound_twice', () => bindCtx(st, makeCtx()));
  });

  testcase('the wrap-position guard fails loudly', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    ctx.client.features.clear();
    ctx.client.features.add(FakeFeature('test'));
    ctx.client.features.add(FakeFeature('retry'));
    ctx.client.features.add(FakeFeature('station'));
    return expectCode('station_wrap_order', () => bindCtx(st, ctx));
  });

  testcase('adopt hoists a resident credential and warns once', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    ctx.options['apikey'] = 'resident-secret';
    check(null != bindCtx(st, ctx), 'bound');
    eq(ctx.options['apikey'], '[station:gnarly-pets]', 'placeholder');
    check(!st.redact('x resident-secret y').contains('resident-secret'),
        'hoisted into the broker');
    eq(
        st
            .events()
            .where((ev) =>
                'station' == ev['kind'] &&
                (ev['meta']?['warn'] ?? '').toString().contains('hoisted'))
            .length,
        1,
        'one hoist warning');
  });

  testcase('copy-on-inject: the wire gets the value, ctx keeps the placeholder',
      () async {
    if (!hasEnv('GNARLY_PETS_APIKEY')) {
      print('     (skipped: GNARLY_PETS_APIKEY not set - use make test)');
      return;
    }
    final apikey = Platform.environment['GNARLY_PETS_APIKEY'];
    final st = Station({'config': null, 'proxy': 'off'});
    dynamic seendef;
    final ctx = makeCtx(inner: (dynamic fctx, dynamic url, dynamic def) async {
      seendef = def;
      return {'status': 200, 'headers': {'content-length': '2'}};
    });
    final binding = bindCtx(st, ctx)!;

    final opctx = FakeCtx(client: ctx.client, utility: ctx.utility);
    binding.prePoint(opctx);

    final fetchdef = <String, dynamic>{
      'method': 'GET',
      'headers': <String, dynamic>{
        'authorization': 'Bearer [station:gnarly-pets]'
      },
    };
    final res = await ctx.utility.fetcher(
        opctx, 'http://localhost:8903/api/pet/p1', fetchdef);
    eq(res['status'], 200, 'response through');

    eq(seendef['headers']['authorization'], 'Bearer ' + apikey!,
        'wire got the real value');
    eq(fetchdef['headers']['authorization'], 'Bearer [station:gnarly-pets]',
        'the ctx-reachable fetchdef keeps the placeholder');

    final http = ofKind(st, 'http');
    eq(http.length, 1, 'one http event');
    eq(http[0]['http']['status'], 200, 'status');
    eq(http[0]['http']['path'], '/api/pet/p1', 'path');
    eq(http[0]['corr'], opctx.out[r'station$']['corr'], 'correlated');

    binding.preDone(opctx..result = FakeResult(ok: true));
    final op = ofKind(st, 'op');
    eq(op.length, 1, 'one op event');
    eq(op[0]['corr'], http[0]['corr'], 'op/http correlate');
    eq(op[0]['op']['outcome'], 'ok', 'outcome');
  });

  testcase('no injection into mock transports', () async {
    final st = Station({'config': null, 'proxy': 'off'});
    dynamic seendef;
    final ctx = makeCtx(inner: (dynamic fctx, dynamic url, dynamic def) async {
      seendef = def;
      return {'status': 200, 'headers': {}};
    });
    bindCtx(st, ctx);
    ctx.client.mode = 'test';
    final fetchdef = <String, dynamic>{
      'method': 'GET',
      'headers': {'authorization': 'Bearer [station:gnarly-pets]'},
    };
    await ctx.utility.fetcher(
        FakeCtx(client: ctx.client), 'http://localhost:8903/api/pet/p1',
        fetchdef);
    eq(seendef['headers']['authorization'], 'Bearer [station:gnarly-pets]',
        'placeholder rode through untouched');
    eq(ofKind(st, 'http').length, 1, 'the mock attempt is still observed');
  });

  testcase('a missing secret is station_secret_no_value on the op path',
      () async {
    if (hasEnv('GNARLY_PETS_APIKEY')) {
      // The value resolving would defeat this case; use a slug-less name.
      return;
    }
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    bindCtx(st, ctx);
    final res = await ctx.utility.fetcher(
        FakeCtx(client: ctx.client), 'http://localhost:8903/api/pet/p1',
        <String, dynamic>{'method': 'GET', 'headers': {}});
    check(res is StationError, 'error value, not a throw');
    eq((res as StationError).code, 'station_secret_no_value', 'code');
    final errs = ofKind(st, 'error');
    eq(errs.length, 1, 'error event');
    eq(errs[0]['err']['code'], 'station_secret_no_value', 'event code');
  });

  testcase('hosts policy: denial and manual redirects', () async {
    final st = Station({
      'proxy': 'off',
      'config': {
        'station': 1,
        'profiles': {
          'default': {
            'sdk': {
              'gnarly-pets': {
                'policy': {
                  'hosts': ['api.ok']
                }
              }
            }
          }
        }
      },
    });
    dynamic seendef;
    final ctx = makeCtx(inner: (dynamic fctx, dynamic url, dynamic def) async {
      seendef = def;
      return {'status': 200, 'headers': {}};
    });
    // Auth-inactive keeps injection out of the way of this case.
    (ctx.config['options'] as Map).remove('auth');
    bindCtx(st, ctx);

    final denied = await ctx.utility.fetcher(FakeCtx(client: ctx.client),
        'http://api.evil/x', <String, dynamic>{'method': 'GET', 'headers': {}});
    check(denied is StationError, 'denied is an error value');
    eq((denied as StationError).code, 'station_host_allow', 'code');
    check(null == seendef, 'inner never called');

    final allowed = await ctx.utility.fetcher(FakeCtx(client: ctx.client),
        'http://api.ok/x', <String, dynamic>{'method': 'GET', 'headers': {}});
    eq(allowed['status'], 200, 'allowed through');
    eq(seendef['redirect'], 'manual',
        'redirects come back manual under a hosts policy');
  });

  testcase('require fails closed on the operation path', () async {
    final st = Station({'config': null, 'proxy': 'require'});
    final ctx = makeCtx();
    bindCtx(st, ctx);
    final res = await ctx.utility.fetcher(FakeCtx(client: ctx.client),
        'http://localhost:8903/x', <String, dynamic>{'method': 'GET'});
    check(res is StationError, 'error value');
    eq((res as StationError).code, 'station_no_proxy', 'code');
  });

  testcase('a retried op yields N station http events', () async {
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    (ctx.config['options'] as Map).remove('auth');
    bindCtx(st, ctx);
    final wrapped = ctx.utility.fetcher;
    final opctx = FakeCtx(client: ctx.client);
    // A retry feature wrapped OUTSIDE station calls the wrap once per
    // attempt - each attempt is wire truth (design station.md 3.3).
    await wrapped(opctx, 'http://localhost:8903/x', {'method': 'GET'});
    await wrapped(opctx, 'http://localhost:8903/x', {'method': 'GET'});
    eq(ofKind(st, 'http').length, 2, 'one http event per attempt');
  });

  testcase('the double-wrap guard trips on a station-wrapped slot', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final ctx = makeCtx();
    bindCtx(st, ctx);
    // A second client (a DIFFERENT plugin, so registration passes) whose
    // transport slot ALREADY carries a station wrap: the marker is the
    // wrap's concrete type, dart's stand-in for the ts closure property.
    final ctx2 = makeCtx();
    (ctx2.config['main'] as Map)['name'] = 'OtherPets';
    (ctx2.config['main'] as Map)['slug'] = 'other-pets';
    ctx2.utility.fetcher = ctx.utility.fetcher;
    return expectCode('station_bound_twice', () => bindCtx(st, ctx2));
  });

  testcase('descriptorOf an unknown plugin lists the candidates', () {
    final st = Station({'config': null, 'proxy': 'off'});
    bindCtx(st, makeCtx());
    try {
      st.descriptorOf('nope');
    } catch (e) {
      check(e is StationError, 'station error');
      eq((e as StationError).code, 'station_no_plugin', 'code');
      check(e.message.contains('gnarly-pets'), 'candidates listed');
      return;
    }
    throw StateError('expected station_no_plugin');
  });
}
