// The station side of the plugin contract (design station.md 3), in ONE
// place: featureBinding() is what both entry paths delegate to -
//  - the GENERATED station feature (sdkgen-station's dart template) calls
//    it from its init() and forwards its hook methods;
//  - the library's carried adapter (adapterFeature, the adopt/connect
//    retrofit for SDKs generated without the feature) is a thin shell
//    over the same call.
// Registration at init, wrap position verified, transport wrapped with
// copy-on-inject, hooks bridged to op events. Anything changed here
// changes both paths - which is the point.
//
// A port of typescript/src/adapter.ts, which is canonical. One Dart
// divergence, by necessity: Dart closures cannot carry marker properties
// (the ts wrap sets `__station__ = true` on the function), so the wrap is
// a CALLABLE CLASS - `utility.fetcher` holds a StationTransport instance
// whose call() signature matches the fetcher slot, and the double-wrap
// guard is an `is StationTransport` check.

import 'error.dart';
import 'station.dart';

// The transport wrap: assigned into the SDK's mutable `utility.fetcher`
// slot (the same assignment-capture every wrapping feature uses); the
// dynamic slot invokes call() like any fetcher function. Its concrete
// type IS the double-wrap marker.
class StationTransport {
  final Station station;
  final String slug;
  final dynamic inner;

  StationTransport(this.station, this.slug, this.inner);

  Future<dynamic> call(dynamic fctx, dynamic fullurl, dynamic fetchdef) {
    return station.transport(slug, inner, fctx, fullurl, fetchdef);
  }
}

// The hook bridge half of a made binding (design station.md 3 item 3):
// operation semantics correlated with the HTTP-level events via a
// per-operation id carried on the SDK's own per-op ctx (ctx.out, the
// per-operation scratch map every generated Context carries).
class FeatureBinding {
  final Station _station;
  final String slug;

  FeatureBinding(this._station, this.slug);

  void prePoint(dynamic ctx) {
    ctx.out[r'station$'] = <String, dynamic>{
      'corr': _station.nextCorr(),
      'start': DateTime.now().millisecondsSinceEpoch,
    };
  }

  void preDone(dynamic ctx) {
    _station.opEvent(slug, ctx, _resultOutcome(ctx));
  }

  void preUnexpected(dynamic ctx) {
    _station.opEvent(slug, ctx, 'unexpected');
  }
}

// Resolve the station this activation binds to: an explicit handle in
// the feature options (connect/adopt and st.options() pass one), else
// the ambient instance. No station open -> null: an activated feature
// with no opened station is an inert no-op that emits nothing and fails
// nothing (design station.md 3.1).
FeatureBinding? featureBinding(dynamic ctx, dynamic fopts) {
  final handle = fopts is Map ? fopts['station'] : null;
  final station = handle is Station ? handle : Station.current();
  if (null == station) {
    return null;
  }

  final client = ctx.client;

  // Same construction, second arrival (generated feature + carried
  // adapter both active on one client): the first bind won, this one is
  // inert. See Station.boundEntry.
  if (null != station.boundEntry(client)) {
    return null;
  }
  final utility = ctx.utility;
  final options = ctx.options;
  final calleropts = fopts is Map ? fopts['calleropts'] : null;

  // Position guard (design station.md 3.3): the wrap must sit
  // immediately outside the base transport - inside retry/cache/
  // ratelimit - or its http events stop being wire truth. Position in
  // client.features IS init order, so verify it and fail loudly.
  final List features = client.features;
  final names = features.map((f) => f.name.toString()).toList();
  final self = names.indexOf('station');
  final testAt = names.indexOf('test');
  final expected = -1 == testAt ? 0 : testAt + 1;
  if (self != expected) {
    throw StationError(
        'station_wrap_order',
        'station must init immediately after the base transport; '
                'feature order is [' +
            names.join(', ') +
            ']');
  }

  final reg = station.register(client, ctx.config, options, calleropts, fopts);
  final binding = reg.binding;
  final profilePlugin = reg.profilePlugin;
  final slug = binding['plugin'].toString();

  // Base URL precedence (design station.md 3.5): caller opts (7) beat
  // the profile (4), which beats the SDK's config default (1) already in
  // options.base. Applied only when the caller opts are knowable - both
  // connect/adopt and st.options() thread them through the activation
  // entry as `calleropts`.
  if (calleropts is Map &&
      null == calleropts['base'] &&
      null != profilePlugin &&
      null != profilePlugin['base']) {
    options['base'] = profilePlugin['base'];
  }

  if ('none' != binding['rung']) {
    final placeholder = binding['placeholder'].toString();

    // A real credential already resident in the options is hoisted into
    // the broker and replaced by the placeholder before construction
    // completes (design station.md 3.1 adopt) - options() and prepare()
    // output become placeholder-safe from here on.
    final resident = options['apikey'];
    if (resident is String && '' != resident && placeholder != resident) {
      station.hoist(slug, resident);
    }
    options['apikey'] = placeholder;
  }

  // Wrap the transport. Copy-on-inject (design station.md 5.3) happens
  // inside Station.transport; auth-inactive plugins skip credential
  // planning but the wrap still observes (design station.md 5.3).
  final inner = utility.fetcher;
  if (inner is StationTransport) {
    throw StationError('station_bound_twice',
        'plugin "' + slug + '" already carries a station wrap');
  }
  utility.fetcher = StationTransport(station, slug, inner);

  return FeatureBinding(station, slug);
}

// The carried adapter: the retrofit path for SDKs generated without the
// station feature (design station.md 3.1 adopt). A duck-typed feature -
// the same name/version/active/options fields and init/invokeHook
// surface the generated BaseFeature protocol expects - whose init and
// hooks delegate to featureBinding. It exists so connect/adopt work on
// any regenerated SDK, and it must stay behaviorally identical to the
// generated feature template in sdkgen-station.
class StationAdapterFeature {
  String version = '0.0.1';
  String name = 'station';
  bool active = true;

  // featureAdd reads options for positioning: immediately after the test
  // feature's base transport (design station.md 3.3). When test is
  // absent from the add order this is a no-op append, which for a bare
  // SDK still lands the wrap immediately outside the base transport.
  Map<String, dynamic> options = <String, dynamic>{'__after__': 'test'};

  final Station _station;
  final dynamic _calleropts;
  FeatureBinding? _binding;

  StationAdapterFeature(this._station, this._calleropts);

  dynamic init(dynamic ctx, dynamic fopts) {
    final merged = <String, dynamic>{};
    if (fopts is Map) {
      fopts.forEach((k, v) => merged[k.toString()] = v);
    }
    merged['station'] = _station;
    merged['calleropts'] = _calleropts;
    _binding = featureBinding(ctx, merged);
    return null;
  }

  // The generated featureHook dispatches by name through invokeHook
  // (Dart has no dynamic property access); this adapter answers only the
  // hooks station declares.
  dynamic invokeHook(String hook, dynamic ctx) {
    switch (hook) {
      case 'PrePoint':
        _binding?.prePoint(ctx);
        return null;
      case 'PreDone':
        _binding?.preDone(ctx);
        return null;
      case 'PreUnexpected':
        _binding?.preUnexpected(ctx);
        return null;
      default:
        return null;
    }
  }
}

StationAdapterFeature adapterFeature(Station station, dynamic calleropts) {
  return StationAdapterFeature(station, calleropts);
}

String _resultOutcome(dynamic ctx) {
  dynamic result;
  try {
    result = ctx.result;
  } catch (_e) {
    return 'unknown';
  }
  if (null == result) {
    return 'unknown';
  }
  try {
    if (null != result.err) {
      return 'err';
    }
    if (false == result.ok) {
      return 'err';
    }
  } catch (_e) {
    return 'unknown';
  }
  return 'ok';
}
