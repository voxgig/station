// A port of typescript/test/placement.test.ts, which is canonical.

import 'dart:async';

import '../lib/voxgig_station.dart';
import 'station.dart';

// What an SDK generated without the station feature does when it is
// constructed: makeOptions' feature order, the constructor's loops,
// featureAdd's anchors and featureInit, as the dart templates write
// them. `statuses` scripts the wire, one status per attempt.
class PlacementFeature {
  String name;
  Map<String, dynamic> options = {};
  PlacementFeature(this.name);

  dynamic init(dynamic ctx, dynamic fopts) {
    final inner = ctx.utility.fetcher;
    if ('test' == name) {
      ctx.utility.fetcher = (dynamic c, dynamic u, dynamic d) async =>
          <String, dynamic>{'status': 200, 'headers': {}};
    } else if ('retry' == name) {
      ctx.utility.fetcher = (dynamic c, dynamic u, dynamic d) async {
        var res = await inner(c, u, d);
        for (var i = 0; i < 2 && 503 == res['status']; i++) {
          res = await inner(c, u, d);
        }
        return res;
      };
    } else {
      ctx.utility.fetcher = (dynamic c, dynamic u, dynamic d) => inner(c, u, d);
    }
    return null;
  }

  dynamic invokeHook(String hook, dynamic ctx) => null;
}

const KNOWN = ['cache', 'retry', 'test'];

List<String> featureorder(Map fmap) {
  final names = fmap.keys.map((k) => k.toString()).toList()..sort();
  final order = <String>[];
  if (names.contains('test')) {
    order.add('test');
  }
  order.addAll(names.where((n) => 'test' != n));
  final si = order.indexOf('station');
  if (0 <= si) {
    order.removeAt(si);
    final ti = order.indexOf('test');
    order.insert(-1 == ti ? 0 : ti + 1, 'station');
  }
  return order;
}

void featureAdd(List features, dynamic f) {
  final dynamic raw = f.options;
  final Map fopts = raw is Map ? raw : {};
  final before = fopts['__before__'];
  final after = fopts['__after__'];
  final repl = fopts['__replace__'];
  if (null != before || null != after || null != repl) {
    for (var i = 0; i < features.length; i++) {
      final ef = features[i];
      if (before == ef.name) {
        features.insert(i, f);
        return;
      } else if (after == ef.name) {
        features.insert(i + 1, f);
        return;
      } else if (repl == ef.name) {
        features[i] = f;
        return;
      }
    }
  }
  features.add(f);
}

Map<String, dynamic> placementConfig() => <String, dynamic>{
      'main': {'name': 'Taskpad', 'slug': 'taskpad', 'version': '1.0.0', 'target': 'dart'},
      'options': {'base': 'http://api.test', 'auth': {'prefix': ''}},
      'entity': {},
      'feature': {'cache': {}, 'retry': {}, 'test': {}},
    };

class PlacementSDK {
  String mode = 'live';
  List<dynamic> features = [];
  final FakeUtility utility = FakeUtility();
  final Map<String, dynamic> options;
  final List<String> sent;

  PlacementSDK(this.options, List<int> statuses, this.sent) {
    final fmap = options['feature'] is Map ? options['feature'] as Map : {};
    if (fmap['test'] is Map && true == fmap['test']['active']) {
      mode = 'test';
    }
    utility.fetcher = (dynamic c, dynamic url, dynamic d) async {
      sent.add(url.toString());
      final at = sent.length - 1;
      return <String, dynamic>{
        'status': at < statuses.length ? statuses[at] : 200,
        'headers': {},
      };
    };
    final ctx = FakeCtx(client: this, utility: utility, options: options, config: placementConfig());

    final extend = options['extend'] is List ? options['extend'] as List : [];
    for (final fname in featureorder(fmap)) {
      final fopts = fmap[fname];
      if (fopts is Map && true == fopts['active']) {
        if (!KNOWN.contains(fname) && extend.any((f) => fname == f.name)) {
          continue;
        }
        featureAdd(features, PlacementFeature(fname));
      }
    }
    for (final f in extend) {
      featureAdd(features, f);
    }
    for (final f in features) {
      final fopts = fmap[f.name];
      if (fopts is Map && true == fopts['active']) {
        f.init(ctx, fopts);
      }
    }
  }

  Future<dynamic> list() async {
    final ctx = FakeCtx(client: this, utility: utility, options: options, config: placementConfig());
    ctx.op = FakeOp('todo', 'list');
    for (final f in features) {
      f.invokeHook('PrePoint', ctx);
    }
    final res = await utility.fetcher(ctx, 'http://api.test/todo',
        <String, dynamic>{'method': 'GET', 'headers': {}});
    ctx.result = FakeResult(ok: 200 == res['status']);
    for (final f in features) {
      f.invokeHook('PreDone', ctx);
    }
    return res;
  }
}

String names(dynamic client) => client.features.map((f) => f.name).join(',');

String wire(Station st) => st
    .events()
    .where((e) => 'http' == e['kind'] || 'op' == e['kind'])
    .map((e) => 'http' == e['kind'] ? 'http ${e['http']['status']}' : 'op ${e['op']['outcome']}')
    .join(',');

String anchor(dynamic fmap) {
  final got = adapterAnchor(fmap);
  final keys = got.keys.toList()..sort();
  return keys.map((k) => '$k=${got[k]}').join(',');
}

void placementCases(void Function(String, FutureOr<void> Function()) testcase) {
  testcase('adapterAnchor: after test when active, else before the first by name', () {
    eq(anchor(null), '', 'null');
    eq(anchor({}), '', 'empty');
    eq(anchor({'station': {'active': true}}), '', 'station alone');
    eq(anchor({'retry': {'active': true}}), '__before__=retry', 'retry');
    eq(anchor({'retry': {'active': true}, 'cache': {'active': true}}), '__before__=cache', 'by name');
    eq(anchor({'cache': {'active': false}, 'retry': {'active': true}}), '__before__=retry', 'inactive');
    eq(anchor({'station': {'active': true}, 'timeout': {'active': true}}), '__before__=timeout',
        'station is never its own anchor');
    eq(anchor({'test': {'active': true}, 'retry': {'active': true}}), '__after__=test', 'test');
    eq(anchor({'test': {'active': false}, 'retry': {'active': true}}), '__before__=retry',
        'inactive test');
    eq(anchor([{'name': 'retry', 'active': true}]), '', 'array form');
  });

  testcase('placement: live, with retry, station is the base wrap', () async {
    final sent = <String>[];
    final st = Station({'config': null, 'proxy': 'off'});
    final client = st.connect((o) => PlacementSDK(o, [503, 200], sent), {
      'apikey': 'real-secret',
      'feature': {'retry': {'active': true}},
    });
    eq(names(client), 'station,retry', 'order');
    await client.list();
    eq(sent.length, 2, 'attempts');
    eq(wire(st), 'http 503,http 200,op ok', 'events');
  });

  testcase('placement: live, with two features, before the first by name', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final client = st.adopt((o) => PlacementSDK(o, [], []), {
      'apikey': 'real-secret',
      'feature': {'retry': {'active': true}, 'cache': {'active': true}},
    });
    eq(names(client), 'station,cache,retry', 'order');
  });

  testcase('placement: test mode, station sits on the mock transport', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final client = st.connect((o) => PlacementSDK(o, [], []), {
      'feature': {'test': {'active': true}, 'retry': {'active': true}},
    });
    eq(names(client), 'test,station,retry', 'order');
  });

  testcase('placement: no other feature, station alone', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final client = st.connect((o) => PlacementSDK(o, [], []), {'apikey': 'real-secret'});
    eq(names(client), 'station', 'order');
  });
}
