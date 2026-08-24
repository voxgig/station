// The station library core, solo mode (design station.md, D1): fully
// functional in-process with no other component running. The proxy (D2)
// is a deferred amplifier - `require` therefore fails on the operation
// path (station.md 2.1/14), and `auto` degrades to solo with one warning
// event.
//
// A port of typescript/src/Station.ts, which is canonical - over the
// env-only secret broker (no Dart sekreto port exists; station.md 2.2).

import 'adapter.dart';
import 'descriptor.dart';
import 'error.dart';
import 'events.dart';
import 'profile.dart';
import 'secrets.dart';

// One registered plugin: descriptor + rung + the client instance the
// binding was made for (design station.md 3.2).
class PluginEntry {
  final String slug;
  final Map<String, dynamic> descriptor;
  final String rung;
  final dynamic client;
  final List<String> warnings;
  PluginEntry(this.slug, this.descriptor, this.rung, this.client, this.warnings);
}

// What register() hands back to the adapter (design station.md 3 item 1).
class RegisterResult {
  final Map<String, dynamic> binding;
  final Map<String, dynamic>? profilePlugin;
  RegisterResult(this.binding, this.profilePlugin);
}

int _corrSeq = 0;

class Station {
  static Station? _ambient;
  static String? _ambientKey;

  final Map<String, dynamic> _opts;
  late final Map<String, dynamic> _profile;
  late final SecretBroker _broker;
  final EventBuffer _buffer = EventBuffer();
  final Map<String, PluginEntry> _registry = {};
  final Map<String, String> _secretOverride = {};
  late final bool _requireProxy;
  bool _closed = false;

  // Ambient instance (design station.md 10.2): open() is the idempotent
  // process-wide singleton; a second open() with conflicting options is
  // an error; `Station(opts)` stays isolated for tests and multi-tenant
  // hosts. open() is non-blocking - solo involves no network, and the
  // deferred proxy probe must never change that.
  static Station open([Map<String, dynamic>? opts]) {
    final key = canonicalSerialize(opts ?? {});
    final ambient = _ambient;
    if (null != ambient) {
      if (key != _ambientKey) {
        throw StationError('station_open_conflict',
            'Station.open() was already called with different options');
      }
      return ambient;
    }
    final st = Station(opts);
    _ambient = st;
    _ambientKey = key;
    return st;
  }

  // The ambient instance, or null - never creates one. The generated
  // station feature binds through this when no explicit handle rides
  // its options (design station.md 3.1: binding is never implicit; only
  // open() creates the ambient instance).
  static Station? current() => _ambient;

  // Test seam: drop the ambient instance.
  static void reset() {
    _ambient = null;
    _ambientKey = null;
  }

  Station([Map<String, dynamic>? opts]) : _opts = opts ?? <String, dynamic>{} {
    final config = _opts.containsKey('config')
        ? _opts['config']
        : loadConfig(_opts['folder'] is String ? _opts['folder'] as String : null);

    _profile = resolveProfile(config, selectProfile(_opts['profile']));
    _broker = SecretBroker(_profile['providers'] is List
        ? List<dynamic>.from(_profile['providers'] as List)
        : null);

    final proxy = _opts['proxy'] ?? 'auto';
    _requireProxy = 'require' == proxy;

    if ('auto' == proxy) {
      // The probe is deferred with the proxy itself; absence degrades
      // to solo with a single warning event naming the cause
      // (station.md 14).
      emit(<String, dynamic>{
        't': _now(),
        'kind': 'station',
        'meta': {'warn': 'proxy absent (not found); running solo'},
      });
    }

    // Env-only honesty (station.md 2.2): a chain naming a store this
    // port cannot answer from is said at construction, not discovered
    // at first request.
    final unsupported = _broker.unsupportedKinds();
    if (unsupported.isNotEmpty) {
      emit(<String, dynamic>{
        't': _now(),
        'kind': 'station',
        'meta': {
          'warn': 'secrets are env-only: no dart sekreto port exists, so '
                  'these configured provider kinds cannot be served in '
                  'solo mode: ' +
              unsupported.join(', '),
        },
      });
    }
  }

  // --- binding forms (design station.md 3.1) ---

  // connect(SDK, opts): station constructs the SDK itself - pass the
  // generated constructor as a tear-off (`TaskpadSDK.new`) or any
  // factory taking the options map. The activation entry plus the
  // extend-supplied carried adapter ride the tolerance in the generated
  // constructor (sdkgen station.md 9.3 change).
  dynamic connect(dynamic sdk, [dynamic opts]) => _construct(sdk, opts);

  // adopt(SDK, opts): the retrofit path - construction-time sugar, not
  // post-hoc attachment (station.md 3.1). In dart it is the same
  // construction as connect; a resident options apikey is hoisted by
  // the adapter.
  dynamic adopt(dynamic sdk, [dynamic opts]) => _construct(sdk, opts);

  dynamic _construct(dynamic sdk, dynamic opts) {
    if (_closed) {
      throw StationError('station_no_plugin', 'station is closed');
    }
    final calleropts = _copy(opts);
    final options = _withActivation(calleropts);
    final extend = <dynamic>[];
    if (calleropts['extend'] is List) {
      extend.addAll(calleropts['extend'] as List);
    }
    // The carried adapter rides extend for SDKs generated WITHOUT the
    // station feature; when the generated class exists the constructor
    // uses it and the extend copy is skipped by name (both delegate to
    // featureBinding, so behavior is identical).
    extend.add(adapterFeature(this, calleropts));
    options['extend'] = extend;
    return sdk(options);
  }

  // Inverted binding (design station.md 3.1): build the plain options
  // map a generated constructor already accepts - the handle, the
  // activation entry, and the profile's per-plugin base (applied by
  // featureBinding at registration, where the slug is known, with the
  // caller opts passed in `extra` still winning).
  Map<String, dynamic> options([dynamic extra]) {
    return _withActivation(_copy(extra));
  }

  Map<String, dynamic> _copy(dynamic opts) {
    final out = <String, dynamic>{};
    if (opts is Map) {
      opts.forEach((k, v) => out[k.toString()] = v);
    }
    return out;
  }

  Map<String, dynamic> _withActivation(Map<String, dynamic> calleropts) {
    final options = <String, dynamic>{...calleropts};
    final fmap = _copy(options['feature']);
    final sopts = _copy(fmap['station']);
    sopts['active'] = true;
    sopts['station'] = this;
    sopts['calleropts'] = calleropts;
    fmap['station'] = sopts;
    options['feature'] = fmap;
    return options;
  }

  // --- registration (design station.md 3 item 1, called by the adapter) ---

  // The registry entry whose client IS this object, or null. Used by
  // featureBinding for idempotency: connect/adopt activate the station
  // entry AND ride the carried adapter on extend, so on an SDK whose
  // generated config carries a real station feature class the same
  // construction reaches featureBinding twice - the second arrival must
  // no-op, while a genuinely second client of the same SDK class still
  // fails register's slug check (station.md 10.2).
  PluginEntry? boundEntry(dynamic client) {
    for (final entry in _registry.values) {
      if (identical(entry.client, client)) {
        return entry;
      }
    }
    return null;
  }

  RegisterResult register(dynamic client, dynamic config, dynamic options,
      dynamic calleropts, dynamic fopts) {
    final normalized = normalizeDescriptor(
        config, options is Map ? options['feature'] : null);
    final descriptor = normalized.descriptor;
    final warnings = normalized.warnings;
    final slug = descriptor['slug'].toString();

    if (_registry.containsKey(slug)) {
      throw StationError(
          'station_bound_twice',
          'plugin "' +
              slug +
              '" is already registered; binding one client twice is an ' +
              'error (station.md 10.2)');
    }

    final profilePlugin = _pluginProfile(slug);

    // Secret name precedence: the feature option (in-code, station.md 9
    // config.options.secret) beats the profile, which beats the
    // descriptor default.
    final fsecret = fopts is Map ? fopts['secret'] : null;
    final secretname = _firstNonEmpty([
          fsecret,
          null == profilePlugin ? null : profilePlugin['secret'],
        ]) ??
        descriptor['auth']['secretname'].toString();
    if (fsecret is String && '' != fsecret) {
      _secretOverride[slug] = fsecret;
    }

    final authActive = true == descriptor['auth']['active'];
    final rung = authActive ? 'R1' : 'none';
    final binding = <String, dynamic>{
      'plugin': slug,
      'placeholder': authActive ? placeholderFor(slug) : null,
      'secretname': authActive ? secretname : null,
      'rung': rung,
    };

    _registry[slug] = PluginEntry(slug, descriptor, rung, client, warnings);

    for (final w in warnings) {
      emit(<String, dynamic>{
        't': _now(),
        'kind': 'station',
        'plugin': slug,
        'meta': {'warn': w},
      });
    }
    emit(<String, dynamic>{
      't': _now(),
      'kind': 'construct',
      'plugin': slug,
      'meta': {
        'name': descriptor['name'],
        'version': descriptor['version'],
        'rung': rung,
      },
    });

    return RegisterResult(binding, profilePlugin);
  }

  void hoist(String slug, String value) {
    _broker.hoist(slug, value);
    emit(<String, dynamic>{
      't': _now(),
      'kind': 'station',
      'plugin': slug,
      'meta': {
        'warn': 'a resident credential was hoisted into the broker and '
            'replaced by the placeholder; prefer configuring the secret '
            'name and letting the environment (or, one day, a dart '
            'sekreto port) resolve it',
      },
    });
  }

  Map<String, dynamic>? _pluginProfile(String slug) {
    final sdk = _profile['sdk'];
    final entry = sdk is Map ? sdk[slug] : null;
    if (entry is Map) {
      final out = <String, dynamic>{};
      entry.forEach((k, v) => out[k.toString()] = v);
      return out;
    }
    return null;
  }

  // --- the transport middleware (design station.md 3.3, 5.3) ---

  Future<dynamic> transport(String slug, dynamic inner, dynamic fctx,
      dynamic fullurl, dynamic fetchdef) async {
    // Fail-closed means traffic (station.md 2.1): with the proxy
    // deferred, `require` can never attach, so every operation fails
    // here - the operation path, never the constructor. The error is
    // RETURNED, not thrown: the generated pipeline checks transport
    // results with iserr.
    if (_requireProxy) {
      final err = StationError('station_no_proxy',
          'proxy: "require" is set and no proxy is attached');
      _emitErr(slug, fctx, err);
      return err;
    }

    final entry = _registry[slug];
    final placeholder = placeholderFor(slug);
    final live = 'live' == _clientMode(fctx);
    final profilePlugin = _pluginProfile(slug);

    // Egress policy (design station.md 16), solo half: the hosts
    // allowlist is enforced at the seam every request crosses. When a
    // policy is present, redirects come back manual - a 3xx is a
    // response like any other, so a Location off the allowlist cannot
    // pull an automatic credentialed follow-up to an unapproved host
    // (station.md 8.2's rule, applied at the library seam).
    final policy = null == profilePlugin ? null : profilePlugin['policy'];
    final hostsval = policy is Map ? policy['hosts'] : null;
    final hosts = hostsval is List ? hostsval : null;
    if (null != hosts && live) {
      var hostname = '';
      final uri = Uri.tryParse(fullurl.toString());
      if (null != uri) {
        hostname = uri.host;
      }
      if (!hosts.contains(hostname)) {
        final err = StationError(
            'station_host_allow',
            'egress to "' +
                hostname +
                '" denied by the hosts policy of plugin "' +
                slug +
                '"');
        _emitErr(slug, fctx, err);
        return err;
      }
    }

    dynamic senddef = fetchdef;
    if (null != hosts && live) {
      senddef = _copyFetchdef(senddef, copyHeaders: false);
      senddef['redirect'] = 'manual';
    }

    // Injection: at the last boundary, below every recording feature,
    // and never into mock transports (station.md 3.3) - in test/mock
    // modes the placeholder rides through untouched, so real credentials
    // never enter in-memory mock stores. Copy-on-inject: the object
    // graph reachable from ctx/spec/ctrl keeps the placeholder, ever
    // (station.md 5.3).
    if (live && null != entry && 'R1' == entry.rung) {
      final secretname = _firstNonEmpty([
            _secretOverride[slug],
            null == profilePlugin ? null : profilePlugin['secret'],
          ]) ??
          entry.descriptor['auth']['secretname'].toString();

      String value;
      try {
        value = _broker.value(slug, secretname.toString());
      } catch (e) {
        _emitErr(slug, fctx, e);
        return e;
      }

      senddef = _copyFetchdef(senddef, copyHeaders: true);
      final headers = senddef['headers'] as Map;
      for (final h in headers.keys.toList()) {
        final v = headers[h];
        if (v is String && v.contains(placeholder)) {
          headers[h] = v.split(placeholder).join(value);
        }
      }
    }

    final corr = _corrOf(fctx);
    final started = _now();

    dynamic res;
    try {
      res = await Future.value(inner(fctx, fullurl, senddef));
    } catch (e) {
      _emitHttp(slug, corr, fullurl, senddef, 0, started, 0);
      _emitErr(slug, fctx, e);
      rethrow;
    }

    if (res is Error || res is Exception) {
      _emitHttp(slug, corr, fullurl, senddef, 0, started, 0);
      _emitErr(slug, fctx, res);
      return res;
    }

    var bytes = 0;
    var status = 0;
    if (res is Map) {
      final s = res['status'];
      if (s is num) {
        status = s.toInt();
      }
      final rheaders = res['headers'];
      final cl = rheaders is Map ? rheaders['content-length'] : null;
      if (null != cl) {
        bytes = int.tryParse(cl.toString()) ?? 0;
      }
    }
    _emitHttp(slug, corr, fullurl, senddef, status, started, bytes);

    return res;
  }

  Map<String, dynamic> _copyFetchdef(dynamic fetchdef,
      {required bool copyHeaders}) {
    final out = <String, dynamic>{};
    if (fetchdef is Map) {
      fetchdef.forEach((k, v) => out[k.toString()] = v);
    }
    if (copyHeaders) {
      final headers = <String, dynamic>{};
      final oheaders = out['headers'];
      if (oheaders is Map) {
        oheaders.forEach((k, v) => headers[k.toString()] = v);
      }
      out['headers'] = headers;
    }
    return out;
  }

  String _clientMode(dynamic fctx) {
    try {
      return (fctx.client.mode ?? '').toString();
    } catch (_e) {
      return '';
    }
  }

  String? _corrOf(dynamic fctx) {
    try {
      final st = fctx.out[r'station$'];
      if (st is Map && st['corr'] is String) {
        return st['corr'] as String;
      }
    } catch (_e) {
      // No out map on this context.
    }
    return null;
  }

  void _emitHttp(String slug, String? corr, dynamic fullurl, dynamic fetchdef,
      int status, int started, int bytes) {
    var host = '';
    var path = '';
    final uri = Uri.tryParse(fullurl.toString());
    if (null != uri && uri.hasAuthority) {
      host = uri.hasPort ? uri.host + ':' + uri.port.toString() : uri.host;
      path = uri.path;
    } else {
      path = fullurl.toString();
    }
    final method =
        (fetchdef is Map ? fetchdef['method'] : null) ?? 'GET';
    emit(<String, dynamic>{
      't': started,
      'kind': 'http',
      'plugin': slug,
      'corr': corr,
      'http': {
        'method': method.toString(),
        'host': host,
        'path': path,
        'status': status,
        'durationMs': _now() - started,
        'bytes': bytes,
      },
    });
  }

  void _emitErr(String slug, dynamic fctx, dynamic err) {
    String? code;
    try {
      final c = (err as dynamic).code;
      if (c is String) {
        code = c;
      }
    } catch (_e) {
      // Not every error carries a code.
    }
    String message;
    try {
      final m = (err as dynamic).message;
      message = m is String && '' != m ? m : err.toString();
    } catch (_e) {
      message = err.toString();
    }
    emit(<String, dynamic>{
      't': _now(),
      'kind': 'error',
      'plugin': slug,
      'corr': _corrOf(fctx),
      'err': {
        'code': code,
        // The scrub keeps an upstream echo of a credential out of the
        // event stream (station.md 7 as revised: exact-value, no length
        // floor).
        'message': redact(message),
      },
    });
  }

  // Op events from the hook bridge (design station.md 3 item 3).
  void opEvent(String slug, dynamic ctx, String outcome) {
    dynamic st;
    try {
      st = ctx.out[r'station$'];
    } catch (_e) {
      st = null;
    }
    final start = st is Map && st['start'] is int ? st['start'] as int : null;
    emit(<String, dynamic>{
      't': _now(),
      'kind': 'op',
      'plugin': slug,
      'corr': st is Map ? st['corr'] : null,
      // ctx.op is the SDK's resolved Operation: name + entity, in the
      // descriptor's lowercase spelling.
      'op': {
        'entity': _opEntity(ctx),
        'op': _opName(ctx),
        'outcome': outcome,
        'durationMs': null != start ? _now() - start : 0,
      },
    });
  }

  String _opEntity(dynamic ctx) {
    try {
      final op = ctx.op;
      if (null != op && null != op.entity) {
        return op.entity.toString();
      }
    } catch (_e) {
      // Fall through to the entity itself.
    }
    try {
      final entity = ctx.entity;
      if (null != entity && null != entity.name) {
        return entity.name.toString();
      }
    } catch (_e) {
      // No entity on this context.
    }
    return '';
  }

  String _opName(dynamic ctx) {
    try {
      final op = ctx.op;
      if (null != op && null != op.name) {
        return op.name.toString();
      }
    } catch (_e) {
      // No op on this context.
    }
    return '';
  }

  // A per-operation correlation id for the hook bridge.
  String nextCorr() => 'c' + (++_corrSeq).toString();

  // --- the query/observe surface (design station.md 3.2, 6) ---

  List<Map<String, dynamic>> plugins() {
    return _registry.values
        .map((e) => <String, dynamic>{
              'slug': e.slug,
              'descriptor': e.descriptor,
              'rung': e.rung,
              'warnings': List<String>.from(e.warnings),
            })
        .toList();
  }

  Map<String, dynamic> descriptorOf(String slug) {
    final entry = _registry[slug];
    if (null == entry) {
      throw StationError(
          'station_no_plugin',
          'unknown plugin "' +
              slug +
              '"; known: [' +
              _registry.keys.join(', ') +
              ']');
    }
    return entry.descriptor;
  }

  String canonicalDescriptor(String slug) {
    return canonicalSerialize(descriptorOf(slug));
  }

  List<Map<String, dynamic>> events() => _buffer.events();

  void Function() tap(TapFn fn) => _buffer.tap(fn);

  Map<String, dynamic> status() {
    return <String, dynamic>{
      'mode': 'solo',
      'profile': _profile['name'],
      'plugins': _registry.values
          .map((e) => <String, dynamic>{'slug': e.slug, 'rung': e.rung})
          .toList(),
      'events': _buffer.status(),
    };
  }

  String redact(dynamic text) => _broker.scrub(text);

  void refreshSecrets() => _broker.refresh();

  bool get closed => _closed;

  // close(): flush (solo: nothing in flight), then warn on profile
  // plugin keys that matched no registered plugin - a typo'd key
  // silently configuring nothing is the worst outcome for a
  // secrets-and-policy file (design station.md 11).
  void close() {
    if (_closed) {
      return;
    }
    final sdk = _profile['sdk'];
    if (sdk is Map) {
      final keys = sdk.keys.map((k) => k.toString()).toList()..sort();
      for (final slug in keys) {
        if (!_registry.containsKey(slug)) {
          emit(<String, dynamic>{
            't': _now(),
            'kind': 'station',
            'meta': {
              'warn': 'profile plugin key "' +
                  slug +
                  '" matched no registered plugin',
            },
          });
        }
      }
    }
    _closed = true;
    if (identical(_ambient, this)) {
      reset();
    }
  }

  void emit(Map<String, dynamic> ev) => _buffer.emit(ev);

  int _now() => DateTime.now().millisecondsSinceEpoch;

  String? _firstNonEmpty(List<dynamic> vals) {
    for (final v in vals) {
      if (v is String && '' != v) {
        return v;
      }
    }
    return null;
  }
}
