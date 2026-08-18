// Error codes follow the SDKs' house grammar (station design 14):
// <subject>_<condition>, absence as no_<thing>, gates as _allow.
// The `errors` corpus section pins the exact strings.
//
// A port of typescript/src/error.ts, which is canonical.

using System;
using System.Collections.Generic;

namespace Voxgig.Station
{
    public class StationError : Exception
    {
        private static readonly List<string> CODES = new List<string>
        {
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
        };

        public readonly string Code;

        public StationError(string code, string message)
            : base(code + ": " + message)
        {
            Code = code;
        }

        public static bool IsKnownCode(object code)
        {
            return code is string text && CODES.Contains(text);
        }
    }
}
