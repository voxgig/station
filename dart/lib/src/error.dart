// Error codes follow the SDKs' house grammar (design station.md 14):
// <subject>_<condition>, absence as no_<thing>, gates as _allow.
// The `errors` corpus section pins the exact strings.
//
// A port of typescript/src/error.ts, which is canonical. StationError
// implements Exception so the generated SDKs' `iserr` (which accepts any
// Error or Exception) treats a returned StationError as an error VALUE -
// the dart pipeline checks errors with iserr, it does not catch them.

const List<String> CODES = [
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
];

class StationError implements Exception {
  final String code;
  final String message;

  StationError(String code, String msg)
      : code = code,
        message = code + ': ' + msg;

  @override
  String toString() => message;
}

bool isKnownCode(dynamic code) => CODES.contains(code);
