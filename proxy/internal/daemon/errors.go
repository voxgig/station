package daemon

import (
	"encoding/json"
	"net/http"
)

// One structured error shape, used by every endpoint (design §8, §14):
//
//	{ "error": { "code": "station_...", "message": "..." } }
//
// Codes follow the SDKs' house grammar (§14): <subject>_<condition>,
// absence as no_<thing>, gates as _allow.
//
// Two kinds of code appear on this wire:
//
//   - Catalog codes, pinned by the `errors` corpus section and
//     station/typescript/src/error.ts. The proxy raises the
//     reserved-for-the-proxy members of that set (`station_protocol`,
//     `station_body_limit`; later phases add `station_grant_expired`,
//     `station_replay_lossy`, `station_agent_allow`, and the
//     `station_no_plugin`/`station_no_entity`/`station_no_op` family).
//
//   - Transport codes for daemon-boundary rejections the shared catalog
//     does not (yet) cover: bearer-token failure, Host/Origin rejection,
//     an unknown session, a malformed register body, an unknown route.
//     Per §14 a library treats auth/proof failures exactly like proxy
//     absence, so none of these surface as an SDK `err.code`; they exist
//     for diagnostics (curl, logs, tap tooling). They keep the house
//     grammar and are candidates for the catalog - see README "Error
//     codes".
const (
	// Catalog codes (error.ts; §14 - the proxy raises its reserved set
	// plus the secret/host/config codes it now shares with the library).
	CodeProtocol      = "station_protocol"        // wire/descriptor version rejected (§8.6)
	CodeBodyLimit     = "station_body_limit"      // request body over the configured limit (§8.5)
	CodeHostAllow     = "station_host_allow"      // egress denied by the hosts policy (§16)
	CodeGrantExpired  = "station_grant_expired"   // grant expired/revoked/unknown; re-register (§5.3)
	CodeSecretNoValue = "station_secret_no_value" // the chain ran and no store had the name (§5.2)
	CodeSecretError   = "station_secret_error"    // a store could not answer; sekreto's message intact (§5.2)
	CodeConfigInvalid = "station_config_invalid"  // proxy-side config cannot support the request (§8.3 approve)
	CodeNoPlugin      = "station_no_plugin"       // unknown plugin in a §7 tool; payload lists candidates
	CodeNoEntity      = "station_no_entity"       // unknown entity in a §7 tool; payload lists candidates
	CodeNoOp          = "station_no_op"           // unknown op in a §7 tool; payload lists candidates
	CodeAgentAllow    = "station_agent_allow"     // agent.read/agent.write gate denial (§7, §16)
	CodeReplayLossy   = "station_replay_lossy"    // replay refused: capture not byte-reconstructable (§8.5)

	// Transport codes (daemon boundary; not yet in the shared catalog).
	CodeTokenAllow      = "station_token_allow"      // bearer token missing or wrong (§8.1)
	CodeOriginAllow     = "station_origin_allow"     // Host/Origin validation failed (§8.1)
	CodeNoSession       = "station_no_session"       // unknown or expired session (§3.4)
	CodeRegisterInvalid = "station_register_invalid" // malformed /v1/register body (§8.2)
	CodeForwardInvalid  = "station_forward_invalid"  // malformed /v1/forward envelope, or unbuildable tool call (§8.2, §7)
	CodeUpstream        = "station_upstream"         // upstream unreachable/failed before a response
	CodeNoRoute         = "station_no_route"         // unknown path or method
	CodeNoCapture       = "station_no_capture"       // station_replay/traffic id not in the store
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

// writeJSON emits v as a JSON response body.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	// Encoding a value built by this package cannot fail; ignore the error
	// (the client vanishing mid-write is not actionable here).
	_ = enc.Encode(v)
}
