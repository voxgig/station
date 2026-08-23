// Error codes follow the SDKs' house grammar (design §14):
// <subject>_<condition>, absence as no_<thing>, gates as _allow.
// The `errors` corpus section pins the exact strings.
//
// A port of typescript/src/error.ts, which is canonical.
package station

var codes = []string{
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
	"station_instance_api",

	// The declarative front door (design §6.4). Availability errors are
	// fatal at first use, not at open().
	"station_no_instance",
	"station_instance_inactive",
	"station_sdk_load",
	"station_no_factory",
	"station_factory_conflict",
}

// Error is anything station refuses to do, carrying its catalog code.
// The message always leads with the code, so substring checks on the
// error text (the corpus convention) see it.
type Error struct {
	Code    string
	Message string
}

func (err *Error) Error() string {
	return err.Code + ": " + err.Message
}

func fail(code string, message string) *Error {
	return &Error{Code: code, Message: message}
}

// IsKnownCode reports whether this is a catalog code (design §14).
func IsKnownCode(code string) bool {
	for _, known := range codes {
		if known == code {
			return true
		}
	}
	return false
}
