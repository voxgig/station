// Error codes follow the SDKs' house grammar (design §14):
// <subject>_<condition>, absence as no_<thing>, gates as _allow.
// The `errors` corpus section pins the exact strings.

const CODES = [
  'station_no_proxy',
  'station_secret_no_value',
  'station_secret_error',
  'station_secret_name',
  'station_host_allow',
  'station_grant_expired',
  'station_wrap_order',
  'station_protocol',
  'station_no_plugin',
  'station_no_entity',
  'station_no_op',
  'station_agent_allow',
  'station_body_limit',
  'station_replay_lossy',
  'station_open_conflict',
  'station_bound_twice',

  // Declarative config (station-declarative-config.md §6.4). Stage 1
  // raises the first three; `station_feature_reserved` is the pure-data
  // half of §8.4/§8.6, checkable before feature.ts exists because both
  // rules are lexical - a `station` key in a feature map, a `feature`
  // key inside `options`.
  'station_config_invalid',
  'station_config_secret',
  'station_secret_collision',
  'station_feature_reserved',

  // Instances (design §6.4). `as` is a tag, not a free name: a full ref
  // whose name is not the SDK's api slug is this.
  'station_instance_api',
  'station_no_instance',
  'station_instance_inactive',
  'station_sdk_load',
  'station_no_factory',
  'station_factory_conflict',

  // Features (design §8.4, §8.5). The checker is derived from the SDK's
  // own declaration, so a feature typo is a CI failure rather than a
  // setting that quietly did nothing in production.
  'station_feature_unknown',
  'station_feature_option',
  'station_feature_order',
] as const

export type StationErrorCode = typeof CODES[number]

export class StationError extends Error {
  code: StationErrorCode

  constructor(code: StationErrorCode, message: string) {
    super(code + ': ' + message)
    this.name = 'StationError'
    this.code = code
  }
}

export function isKnownCode(code: string): boolean {
  return (CODES as readonly string[]).includes(code)
}
