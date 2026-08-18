// Error codes follow the SDKs' house grammar (station design 14):
// <subject>_<condition>, absence as no_<thing>, gates as _allow.
// The `errors` corpus section pins the exact strings.
//
// A port of typescript/src/error.ts, which is canonical.

import Foundation

public final class StationError: Error, CustomStringConvertible {
  private static let codes: Set<String> = [
    "station_no_proxy",
    "station_secret_no_value",
    "station_secret_error",
    "station_secret_name",
    "station_host_allow",
    "station_grant_expired",
    "station_wrap_order",
    "station_protocol",
    "station_no_plugin",
    "station_no_entity",
    "station_no_op",
    "station_agent_allow",
    "station_body_limit",
    "station_replay_lossy",
    "station_open_conflict",
    "station_bound_twice",
  ]

  public let code: String
  public let message: String

  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = code + ": " + message
  }

  public var description: String { return message }

  public static func isKnownCode(_ code: String?) -> Bool {
    guard let code = code else { return false }
    return codes.contains(code)
  }
}

/// A malformed-JSON failure (station.json parsing). Not a catalog code:
/// like the elixir and lua ports, a config file that does not parse is a
/// plain "station: ..." error, not a StationError.
public struct JsonError: Error, CustomStringConvertible {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { return message }
}
