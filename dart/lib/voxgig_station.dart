// voxgig_station - one control surface for outbound integrations.
//
// Dart port of the canonical TypeScript implementation
// (typescript/src/). Solo mode only in v1 (the proxy is a deferred
// amplifier): plugin registry, profiles, env-only secret broker with
// placeholder injection, bounded event ring + tap, descriptor
// normalizer and canonical serializer.

export 'src/adapter.dart'
    show FeatureBinding, StationAdapterFeature, StationTransport,
        adapterFeature, featureBinding;
export 'src/descriptor.dart'
    show Normalized, canonicalSerialize, envtoken, normalizeDescriptor,
        secretnameDefault;
export 'src/error.dart' show CODES, StationError, isKnownCode;
export 'src/events.dart' show EventBuffer, TapFn;
export 'src/profile.dart'
    show MERGE_SENSITIVE, findConfigFile, loadConfig, refapi, resolveProfile,
        selectProfile;
export 'src/secrets.dart' show SecretBroker, envkey, placeholderFor, validname;
export 'src/station.dart' show PluginEntry, RegisterResult, Station;
