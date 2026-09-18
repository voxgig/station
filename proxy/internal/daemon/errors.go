package daemon

import (
	"encoding/json"
	"net/http"
)

const (
	// Catalog codes (error.ts; §14 - the proxy raises its reserved set
	// plus the secret/host/config codes it now shares with the library).
	CodeProtocol      = "station_protocol"
	CodeBodyLimit     = "station_body_limit"
	CodeHostAllow     = "station_host_allow"
	CodeGrantExpired  = "station_grant_expired"
	CodeSecretNoValue = "station_secret_no_value"
	CodeSecretError   = "station_secret_error"
	CodeConfigInvalid = "station_config_invalid" // proxy-side config cannot support the request (§8.3 approve)
	CodeNoPlugin      = "station_no_plugin"
	CodeNoEntity      = "station_no_entity"
	CodeNoOp          = "station_no_op"
	CodeAgentAllow    = "station_agent_allow"
	CodeReplayLossy   = "station_replay_lossy"

	CodeTokenAllow      = "station_token_allow"
	CodeOriginAllow     = "station_origin_allow"
	CodeNoSession       = "station_no_session"
	CodeRegisterInvalid = "station_register_invalid"
	CodeForwardInvalid  = "station_forward_invalid" // malformed /v1/forward envelope, or unbuildable tool call (§8.2, §7)
	CodeUpstream        = "station_upstream"        // upstream unreachable/failed before a response
	CodeNoRoute         = "station_no_route"
	CodeNoCapture       = "station_no_capture"
)

type wireError struct {
	Error wireErrorBody `json:"error"`
}

type wireErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// writeError emits the structured error shape with the given HTTP status.
func writeError(w http.ResponseWriter, status int, code string, message string) {
	writeJSON(w, status, wireError{Error: wireErrorBody{Code: code, Message: message}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	// Encoding a value built by this package cannot fail; ignore the error
	// (the client vanishing mid-write is not actionable here).
	_ = enc.Encode(v)
}
