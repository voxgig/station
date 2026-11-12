// A port of typescript/test/exposure.test.ts, which is canonical.

import 'dart:async';

import '../lib/voxgig_station.dart';
import 'placement.dart';
import 'station.dart';

const SECRET = 'exposure-key-101';

void exposureCases(void Function(String, FutureOr<void> Function()) testcase) {
  testcase('exposure: the caller\'s own key does not ride the activation entry', () async {
    final st = Station({'config': null, 'proxy': 'off'});
    final client = st.adopt((o) => PlacementSDK(o, [], []), {'apikey': SECRET});
    await client.list();

    check(!client.options.toString().contains(SECRET), 'the options hold no secret');
    check(!client.options['feature']['station']['calleropts'].containsKey('apikey'),
        'the entry keeps no key');
  });

  testcase('exposure: inverted binding, the activation entry holds no key', () {
    final st = Station({'config': null, 'proxy': 'off'});
    final options = st.options({'apikey': SECRET});
    eq(options['apikey'], SECRET, 'the SDK still gets the key it is given');
    check(!options['feature']['station'].toString().contains(SECRET), 'the entry holds no secret');
  });
}
