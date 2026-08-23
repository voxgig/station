// Error codes follow the SDKs' house grammar (station design 14):
// <subject>_<condition>, absence as no_<thing>, gates as _allow.
// The `errors` corpus section pins the exact strings.
//
// A port of typescript/src/error.ts, which is canonical.

package com.voxgig.station;

import java.util.List;

public class StationError extends RuntimeException {

  private static final long serialVersionUID = 1L;

  private static final List<String> CODES = List.of(
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

      // Declarative config (design §6.4). Only the reference ports raise
      // the config-validation codes so far (Stage 1); the catalog is
      // repo-wide, so every port knows them.
      "station_config_invalid",
      "station_config_secret",
      "station_secret_collision",
      "station_feature_reserved",

      // Instances (design §6.4). `as` is a tag, not a free name.
      "station_instance_api");

  public final String code;

  public StationError(String code, String message) {
    super(code + ": " + message);
    this.code = code;
  }

  public static boolean isKnownCode(Object code) {
    return code instanceof String && CODES.contains(code);
  }
}
