package daemon

import (
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestContract walks the whole §8 surface end-to-end against ONE
// spawned daemon, in the order a library client lives it. Every piece
// has a unit suite of its own; this walk proves they COMPOSE - the
// §11/§12 loop as a protocol narrative:
//
//	discover -> prove -> authenticate -> register (pending) -> approve
//	-> re-register (grant) -> forward with injection -> capture -> tap
//	-> revoke -> expire -> renew -> close
//
// followed by the negative table: every §8 rejection in one place.
func TestContract(t *testing.T) {
	up := newUpstream(t)
	clk := newFakeClock()
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "proxy", "full")
	statePath := filepath.Join(t.TempDir(), "approvals.json")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
		c.StatePath = statePath
		c.Now = clk.Now
		c.SessionTTL = time.Hour
		c.GrantTTL = 10 * time.Minute
	})

	const ref = "voxgig-solardemo"
	var session string
	var grant string

	// --- §8.1: discovery and the proof-of-token handshake. The client
	// knows only an address and the token file; before it sends the
	// bearer token, an envelope, or an event, it challenges the port:
	// only the process holding the 0600 token file can answer.
	t.Run("01 discovery: nonce -> Station-Proof -> verify", func(t *testing.T) {
		nonce := "contract-nonce-1"
		resp := call(t, ts, http.MethodGet, "/v1/health?nonce="+nonce, "",
			map[string]string{"Authorization": "", "Station-Protocol": ""}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("health = %d", resp.StatusCode)
		}
		proof := resp.Header.Get("Station-Proof")
		if proof != Proof(testToken, nonce) {
			t.Fatal("proof does not verify against the shared token: imposter")
		}
		// An imposter that guessed a token cannot produce this proof -
		// the client-side check that fails (and reads as absence, §14).
		if proof == Proof("attacker-guess", nonce) {
			t.Fatal("proof must be keyed by the real token")
		}
	})

	// --- §8.1: only now does the bearer token flow.
	t.Run("02 bearer token accepted", func(t *testing.T) {
		resp := call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("authenticated status = %d", resp.StatusCode)
		}
	})

	// --- §8.2/§8.3: registration parks in pending - no first-seen
	// shortcut, nothing proxy-side derived from the untrusted
	// descriptor - while capture and library-resolved traffic work.
	t.Run("03 register -> pending", func(t *testing.T) {
		var binding map[string]any
		session, binding = registerInstance(t, ts, ref, up.ts.URL)
		if binding["state"] != StatePending {
			t.Fatalf("state = %v, want pending", binding["state"])
		}
		if _, has := binding["grant"]; has {
			t.Fatal("pending binding must not carry a grant")
		}
		resp := forward(t, ts, session, nil, envelope(t, up.ts.URL+"/pending-ok", "GET", nil, ""))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("pending traffic = %d, want 200 (§8.3)", resp.StatusCode)
		}
	})

	// --- §8.3: an explicit human decision blesses the triple.
	t.Run("04 approve blesses the triple", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/approve/"+ref, "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("approve = %d", resp.StatusCode)
		}
		approval := decode(t, resp)["approval"].(map[string]any)
		if approval["secret"] != "voxgig_solardemo.apikey" {
			t.Fatalf("blessed secret name = %v", approval["secret"])
		}
	})

	// --- §3.4/§5.3: re-registration picks the approval up and mints
	// the per-instance R2 grant (D-2026-08-24-1).
	t.Run("05 re-register -> approved, grant issued", func(t *testing.T) {
		var binding map[string]any
		session, binding = registerInstance(t, ts, ref, up.ts.URL)
		if binding["state"] != StateApproved {
			t.Fatalf("state = %v, want approved", binding["state"])
		}
		grant, _ = binding["grant"].(string)
		if grant == "" {
			t.Fatal("approved resolve:proxy binding must carry a grant")
		}
	})

	// --- §8.2/§5.3: the data plane, injected. The envelope carries the
	// inert placeholder; the proxy resolves through ITS OWN sekreto by
	// ITS OWN mapping and the upstream sees the real credential - which
	// the application process never held.
	t.Run("06 forward with injection", func(t *testing.T) {
		up.respond = func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-Up", "yes")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, "hello, and your key is %s", testSecret) // hostile echo
		}
		resp := forward(t, ts, session, map[string]string{"Station-Grant": grant},
			envelope(t, up.ts.URL+"/planets", "GET", map[string]any{
				"Authorization": "Bearer [station:voxgig-solardemo]",
			}, ""))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("forward = %d", resp.StatusCode)
		}
		if got := resp.Header.Get("Station-Status"); got != "200" {
			t.Errorf("Station-Status = %q", got)
		}
		if got := resp.Header.Get("Station-Up-X-Up"); got != "yes" {
			t.Errorf("Station-Up-X-Up = %q", got)
		}
		if got := up.last(t).Headers.Get("Authorization"); got != "Bearer "+testSecret {
			t.Errorf("upstream Authorization = %q, want the injected credential", got)
		}
	})

	// --- §8.5/§15: the exchange is captured, scrubbed at capture time.
	// The upstream echoed the credential; the store must not hold it.
	t.Run("07 capture visible and scrubbed", func(t *testing.T) {
		st := decode(t, call(t, ts, http.MethodGet, "/v1/status", "", nil, ""))
		if entries := st["captures"].(map[string]any)["entries"].(float64); entries < 2 {
			t.Errorf("captures.entries = %v, want >= 2", entries)
		}
		dump := srv.captures.DumpForScan()
		if strings.Contains(dump, testSecret) {
			t.Fatal("the injected secret appears in the capture store")
		}
		if !strings.Contains(dump, redactedMarker) {
			t.Error("the echoed credential should have left a redaction marker")
		}
	})

	// --- §6/§8.2: events batch in, liveness rides along, and the tap
	// streams them live to the operator.
	t.Run("08 events flow to tap", func(t *testing.T) {
		lines, cancel := tapStream(t, ts, "")
		defer cancel()
		event := `{"t":1,"session":"` + session + `","plugin":"` + ref + `","kind":"op","op":{"entity":"planet","op":"list","outcome":"ok","durationMs":3}}`
		resp := call(t, ts, http.MethodPost, "/v1/events", event+"\n",
			map[string]string{"Station-Session": session}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("events = %d", resp.StatusCode)
		}
		if got := expectLine(t, lines); got != event {
			t.Errorf("tap line = %q, want the event verbatim", got)
		}
	})

	// --- §5.3: revocation is the operator's hammer, per instance.
	t.Run("09 revoke kills the grant", func(t *testing.T) {
		resp := call(t, ts, http.MethodDelete, "/v1/grants/"+ref, "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("revoke = %d", resp.StatusCode)
		}
		resp = forward(t, ts, session, map[string]string{"Station-Grant": grant},
			envelope(t, up.ts.URL+"/after-revoke", "GET", nil, ""))
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("revoked grant forward = %d, want 403", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeGrantExpired {
			t.Errorf("code = %q, want %q", got, CodeGrantExpired)
		}
	})

	// --- §3.4/§5.3: grants age out on TTL; renewal is always a full
	// re-registration.
	t.Run("10 grant expires, re-registration renews", func(t *testing.T) {
		var binding map[string]any
		session, binding = registerInstance(t, ts, ref, up.ts.URL)
		grant, _ = binding["grant"].(string)

		clk.Advance(11 * time.Minute) // grant TTL 10m; session TTL 1h
		resp := forward(t, ts, session, map[string]string{"Station-Grant": grant},
			envelope(t, up.ts.URL+"/stale", "GET", nil, ""))
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("expired grant forward = %d, want 403", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeGrantExpired {
			t.Errorf("code = %q, want %q", got, CodeGrantExpired)
		}

		session, binding = registerInstance(t, ts, ref, up.ts.URL)
		grant = binding["grant"].(string)
		resp = forward(t, ts, session, map[string]string{"Station-Grant": grant},
			envelope(t, up.ts.URL+"/fresh", "GET", map[string]any{
				"Authorization": "Bearer [station:voxgig-solardemo]",
			}, ""))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("renewed forward = %d", resp.StatusCode)
		}
	})

	// --- §3.4: clean shutdown, idempotent.
	t.Run("11 session delete", func(t *testing.T) {
		resp := call(t, ts, http.MethodDelete, "/v1/session", "",
			map[string]string{"Station-Session": session}, "")
		if d := decode(t, resp); d["removed"] != true {
			t.Fatalf("delete removed = %v, want true", d["removed"])
		}
		resp = call(t, ts, http.MethodDelete, "/v1/session", "",
			map[string]string{"Station-Session": session}, "")
		if d := decode(t, resp); d["removed"] != false {
			t.Errorf("second delete removed = %v, want false (idempotent, §3.4)", d["removed"])
		}
		st := decode(t, call(t, ts, http.MethodGet, "/v1/status", "", nil, ""))
		for _, s := range st["sessions"].([]any) {
			if s.(map[string]any)["session"] == session {
				t.Error("deleted session still listed in status")
			}
		}
	})

	// --- The negative table: every §8 rejection, one place. Each row
	// names its trigger and the exact catalog/transport code.
	t.Run("12 negatives", func(t *testing.T) {
		// A live approved session for the rows that need one.
		negSession, negBinding := registerInstance(t, ts, ref, up.ts.URL)
		negGrant := negBinding["grant"].(string)
		clk.Advance(11 * time.Minute) // expire negGrant; sessions live 1h

		cases := []struct {
			name       string
			run        func(t *testing.T) *http.Response
			wantStatus int
			wantCode   string
		}{
			{"missing bearer token", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodGet, "/v1/status", "",
					map[string]string{"Authorization": ""}, "")
			}, http.StatusUnauthorized, CodeTokenAllow},

			{"wrong bearer token", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodGet, "/v1/status", "",
					map[string]string{"Authorization": "Bearer not-it"}, "")
			}, http.StatusUnauthorized, CodeTokenAllow},

			{"unknown protocol version", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodGet, "/v1/status", "",
					map[string]string{"Station-Protocol": "2"}, "")
			}, http.StatusBadRequest, CodeProtocol},

			{"missing protocol version", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodGet, "/v1/status", "",
					map[string]string{"Station-Protocol": ""}, "")
			}, http.StatusBadRequest, CodeProtocol},

			{"rebound Host header", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodGet, "/v1/status", "", nil, "evil.example.com")
			}, http.StatusForbidden, CodeOriginAllow},

			{"oversized register body", func(t *testing.T) *http.Response {
				big := `{"descriptor":{"pad":"` + strings.Repeat("x", int(DefaultRegisterBodyLimit)+64) + `"}}`
				return call(t, ts, http.MethodPost, "/v1/register", big, nil, "")
			}, http.StatusRequestEntityTooLarge, CodeBodyLimit},

			{"off-allowlist egress", func(t *testing.T) *http.Response {
				return forward(t, ts, negSession, nil,
					envelope(t, "http://evil.example/exfil", "GET", nil, ""))
			}, http.StatusForbidden, CodeHostAllow},

			{"expired grant", func(t *testing.T) *http.Response {
				return forward(t, ts, negSession, map[string]string{"Station-Grant": negGrant},
					envelope(t, up.ts.URL+"/late", "GET", nil, ""))
			}, http.StatusForbidden, CodeGrantExpired},

			{"unknown session", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodPost, "/v1/events", `{"kind":"op"}`,
					map[string]string{"Station-Session": "who-dis"}, "")
			}, http.StatusNotFound, CodeNoSession},

			{"unknown route", func(t *testing.T) *http.Response {
				return call(t, ts, http.MethodGet, "/v1/nothing-here", "", nil, "")
			}, http.StatusNotFound, CodeNoRoute},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				resp := c.run(t)
				if resp.StatusCode != c.wantStatus {
					t.Fatalf("status = %d, want %d", resp.StatusCode, c.wantStatus)
				}
				if got := errCode(t, resp); got != c.wantCode {
					t.Errorf("code = %q, want %q", got, c.wantCode)
				}
			})
		}
	})
}
