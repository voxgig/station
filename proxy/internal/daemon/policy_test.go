package daemon

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The proxy-side secret for the covered instance in these tests. The
// memory provider keys values like environment variables: the sekreto
// name voxgig_solardemo.apikey resolves via VOXGIG_SOLARDEMO_APIKEY.
const testSecret = "sk-live-supersecret-9"

// stationJSONFor writes a proxy-side station.json covering
// voxgig-solardemo with the given hosts, resolve and capture settings.
func stationJSONFor(t *testing.T, hosts string, resolve string, capture string) string {
	t.Helper()
	text := fmt.Sprintf(`{
  "station": 1,
  "profiles": {
    "default": {
      "secrets": { "providers": [
        { "kind": "memory", "values": { "VOXGIG_SOLARDEMO_APIKEY": %q } } ] },
      "sdk": {
        "voxgig-solardemo": {
          "resolve": %q, "capture": %q,
          "policy": { "hosts": [%s] } } } } } }`,
		testSecret, resolve, capture, hosts)
	path := filepath.Join(t.TempDir(), "station.json")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// --- §8.3: pending -> approve -> narrow-not-widen ----------------------

func TestPolicyAuthority(t *testing.T) {
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1", "allowed.example"`, "proxy", "meta")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	_ = srv

	// Registered but unapproved: §8.3 - no first-seen shortcut. The
	// binding says pending, carries no grant, and proxy-side resolution
	// is unusable; capture and library-resolved traffic still work.
	session, binding := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
	if binding["state"] != StatePending {
		t.Fatalf("pre-approval state = %v, want pending", binding["state"])
	}
	if _, has := binding["grant"]; has {
		t.Fatal("pending binding must not carry a grant")
	}
	if binding["resolve"] != "proxy" {
		t.Errorf("binding.resolve = %v, want proxy (from proxy-side config)", binding["resolve"])
	}
	resp := forward(t, ts, session, nil, envelope(t, up.ts.URL+"/while-pending", "GET", nil, ""))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("pending forward status = %d, want 200 (§8.3: traffic works while pending)", resp.StatusCode)
	}

	// Approve: an explicit decision blesses the base/hosts/name triple.
	resp = call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("approve status = %d", resp.StatusCode)
	}
	approval := decode(t, resp)["approval"].(map[string]any)
	if approval["secret"] != "voxgig_solardemo.apikey" {
		t.Errorf("approved secret name = %v, want voxgig_solardemo.apikey (§5.1 derivation)", approval["secret"])
	}
	hosts := approval["hosts"].([]any)
	if len(hosts) != 2 || hosts[0] != "127.0.0.1" || hosts[1] != "allowed.example" {
		t.Errorf("approved hosts = %v", hosts)
	}

	// Re-registration picks up approval and yields a per-instance grant
	// (renewal by re-registration, §3.4; D-2026-08-24-1).
	session2, binding2 := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
	if binding2["state"] != StateApproved {
		t.Fatalf("post-approval state = %v, want approved", binding2["state"])
	}
	grant, _ := binding2["grant"].(string)
	if grant == "" {
		t.Fatal("approved resolve:proxy binding must carry a grant")
	}
	if ttl, _ := binding2["grantTtlSeconds"].(float64); ttl != DefaultGrantTTL.Seconds() {
		t.Errorf("grantTtlSeconds = %v, want %v", ttl, DefaultGrantTTL.Seconds())
	}
	if binding2["secret"] != "voxgig_solardemo.apikey" {
		t.Errorf("binding.secret = %v (name only)", binding2["secret"])
	}
	// The descriptor's base host (127.0.0.1) is INSIDE the approved
	// allowlist, so it narrows the effective hosts to itself (§8.3).
	narrowed := binding2["hosts"].([]any)
	if len(narrowed) != 1 || narrowed[0] != "127.0.0.1" {
		t.Errorf("binding.hosts = %v, want narrowed [127.0.0.1]", narrowed)
	}

	// R2 injection: the proxy resolves through ITS OWN sekreto by ITS
	// OWN mapping and swaps the placeholder for the value upstream.
	up.respond = nil
	resp = forward(t, ts, session2, map[string]string{"Station-Grant": grant},
		envelope(t, up.ts.URL+"/authed", "GET", map[string]any{
			"Authorization": "Bearer [station:voxgig-solardemo]",
		}, ""))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("injected forward status = %d", resp.StatusCode)
	}
	if got := up.last(t).Headers.Get("Authorization"); got != "Bearer "+testSecret {
		t.Errorf("upstream Authorization = %q, want injected credential with scheme preserved", got)
	}

	// Narrowing enforced: allowed.example is in the APPROVED list but
	// outside this session's descriptor-narrowed list.
	resp = forward(t, ts, session2, nil, envelope(t, "http://allowed.example/x", "GET", nil, ""))
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("narrowed-away host status = %d, want 403", resp.StatusCode)
	}
	if got := errCode(t, resp); got != CodeHostAllow {
		t.Errorf("code = %q, want %q", got, CodeHostAllow)
	}

	// Widening ignored: a descriptor claiming an off-allowlist base
	// cannot widen approved policy - egress to it is still denied, and
	// the approved allowlist stays in force unnarrowed.
	session3, _ := registerInstance(t, ts, "voxgig-solardemo", "http://evil.example")
	resp = forward(t, ts, session3, nil, envelope(t, "http://evil.example/exfil", "GET", nil, ""))
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("evil-host forward status = %d, want 403 (§8.3: never widen)", resp.StatusCode)
	}
	if got := errCode(t, resp); got != CodeHostAllow {
		t.Errorf("code = %q, want %q", got, CodeHostAllow)
	}
	resp = forward(t, ts, session3, nil, envelope(t, up.ts.URL+"/still-fine", "GET", nil, ""))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("allowlisted forward for widening session = %d, want 200", resp.StatusCode)
	}

	// Status reflects the new stores.
	st := decode(t, call(t, ts, http.MethodGet, "/v1/status", "", nil, ""))
	pol := st["policy"].(map[string]any)
	if covered := pol["covered"].([]any); len(covered) != 1 || covered[0] != "voxgig-solardemo" {
		t.Errorf("status policy.covered = %v", covered)
	}
	if approved := pol["approved"].([]any); len(approved) != 1 || approved[0] != "voxgig-solardemo" {
		t.Errorf("status policy.approved = %v", approved)
	}
	if active := st["grants"].(map[string]any)["active"].(float64); active < 1 {
		t.Errorf("status grants.active = %v, want >= 1", active)
	}
	if entries := st["captures"].(map[string]any)["entries"].(float64); entries < 3 {
		t.Errorf("status captures.entries = %v, want >= 3", entries)
	}
}

// TestApproveHostsDefault covers §16's hosts default: with no proxy-side
// hosts or base, approve falls back to the proxy-side view of a live
// registration's descriptor base - and refuses when there is nothing at
// all to bound egress with.
func TestApproveHostsDefault(t *testing.T) {
	up := newUpstream(t)
	ts := newTestProxy(t, nil) // no proxy-side config

	t.Run("nothing to derive hosts from", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/approve/ghost-api", "", nil, "")
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeConfigInvalid {
			t.Errorf("code = %q, want %q", got, CodeConfigInvalid)
		}
	})

	t.Run("descriptor base of a live registration", func(t *testing.T) {
		session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
		resp := call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("approve status = %d", resp.StatusCode)
		}
		hosts := decode(t, resp)["approval"].(map[string]any)["hosts"].([]any)
		if len(hosts) != 1 || hosts[0] != "127.0.0.1" {
			t.Errorf("defaulted hosts = %v, want [127.0.0.1]", hosts)
		}
		// The blessed allowlist is now enforced for this uncovered-
		// by-config instance too.
		resp = forward(t, ts, session, nil, envelope(t, "http://evil.example/x", "GET", nil, ""))
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("off-allowlist forward = %d, want 403", resp.StatusCode)
		}
	})
}

// TestApprovalPersistence: approvals survive restart via the state file
// (triples only), and a config change to the blessed triple re-enters
// pending (§8.3).
func TestApprovalPersistence(t *testing.T) {
	up := newUpstream(t)
	statePath := filepath.Join(t.TempDir(), "approvals.json")
	cfgA := stationJSONFor(t, `"127.0.0.1"`, "proxy", "meta")

	ts1, _ := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgA
		c.StatePath = statePath
	})
	if resp := call(t, ts1, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, ""); resp.StatusCode != http.StatusOK {
		t.Fatalf("approve status = %d", resp.StatusCode)
	}

	// The state file holds triples and NEVER secret values.
	text, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("state file: %v", err)
	}
	if !strings.Contains(string(text), "voxgig_solardemo.apikey") {
		t.Errorf("state file should carry the blessed secret NAME")
	}
	if strings.Contains(string(text), testSecret) {
		t.Errorf("state file must never hold a secret VALUE")
	}

	// Restart with the same config: approval survives.
	ts2, _ := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgA
		c.StatePath = statePath
	})
	_, binding := registerInstance(t, ts2, "voxgig-solardemo", up.ts.URL)
	if binding["state"] != StateApproved {
		t.Fatalf("post-restart state = %v, want approved (persisted)", binding["state"])
	}

	// Restart with a CHANGED hosts triple: re-enters pending (§8.3 -
	// any later change to the blessed base/hosts/name triple).
	cfgB := stationJSONFor(t, `"other.example"`, "proxy", "meta")
	ts3, _ := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgB
		c.StatePath = statePath
	})
	_, binding = registerInstance(t, ts3, "voxgig-solardemo", up.ts.URL)
	if binding["state"] != StatePending {
		t.Fatalf("changed-triple state = %v, want pending", binding["state"])
	}
}

// --- §5.3 / D-2026-08-24-1: grants -------------------------------------

func TestGrantLifecycle(t *testing.T) {
	up := newUpstream(t)
	clk := newFakeClock()
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "proxy", "meta")
	ts, _ := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
		c.Now = clk.Now
		c.SessionTTL = time.Hour
		c.GrantTTL = time.Minute
	})
	if resp := call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, ""); resp.StatusCode != http.StatusOK {
		t.Fatalf("approve: %d", resp.StatusCode)
	}

	authedEnvelope := func() string {
		return envelope(t, up.ts.URL+"/g", "GET", map[string]any{
			"Authorization": "Bearer [station:voxgig-solardemo]",
		}, "")
	}
	session, binding := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
	grant1, _ := binding["grant"].(string)
	if grant1 == "" {
		t.Fatal("no grant issued at register")
	}

	t.Run("issued grant injects", func(t *testing.T) {
		resp := forward(t, ts, session, map[string]string{"Station-Grant": grant1}, authedEnvelope())
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d", resp.StatusCode)
		}
		if got := up.last(t).Headers.Get("Authorization"); got != "Bearer "+testSecret {
			t.Errorf("upstream Authorization = %q", got)
		}
	})

	t.Run("revocation is per instance", func(t *testing.T) {
		resp := call(t, ts, http.MethodDelete, "/v1/grants/voxgig-solardemo", "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("revoke status = %d", resp.StatusCode)
		}
		if revoked := decode(t, resp)["revoked"].(float64); revoked != 1 {
			t.Errorf("revoked = %v, want 1", revoked)
		}
		resp = forward(t, ts, session, map[string]string{"Station-Grant": grant1}, authedEnvelope())
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("revoked-grant forward = %d, want 403", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeGrantExpired {
			t.Errorf("code = %q, want %q", got, CodeGrantExpired)
		}
	})

	var grant2 string
	t.Run("renewal by re-registration", func(t *testing.T) {
		s2, b2 := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
		grant2, _ = b2["grant"].(string)
		if grant2 == "" || grant2 == grant1 {
			t.Fatalf("re-registration must mint a fresh grant, got %q", grant2)
		}
		session = s2
		resp := forward(t, ts, session, map[string]string{"Station-Grant": grant2}, authedEnvelope())
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("renewed-grant forward = %d", resp.StatusCode)
		}
	})

	t.Run("expiry", func(t *testing.T) {
		clk.Advance(2 * time.Minute) // grant TTL is 1m; session TTL 1h
		resp := forward(t, ts, session, map[string]string{"Station-Grant": grant2}, authedEnvelope())
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("expired-grant forward = %d, want 403", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeGrantExpired {
			t.Errorf("code = %q, want %q", got, CodeGrantExpired)
		}
		// Re-registration renews (§3.4) and traffic resumes.
		s3, b3 := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
		grant3, _ := b3["grant"].(string)
		resp = forward(t, ts, s3, map[string]string{"Station-Grant": grant3}, authedEnvelope())
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("post-renewal forward = %d", resp.StatusCode)
		}
	})

	t.Run("grant bound to its instance", func(t *testing.T) {
		// A session of a different instance cannot spend this grant.
		sOther, _ := registerInstance(t, ts, "other-api", up.ts.URL)
		resp := forward(t, ts, sOther, map[string]string{"Station-Grant": grant2}, authedEnvelope())
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("cross-instance grant = %d, want 403", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeGrantExpired {
			t.Errorf("code = %q, want %q", got, CodeGrantExpired)
		}
	})
}

// --- §8.2: policy long-poll --------------------------------------------

func TestPolicyLongPoll(t *testing.T) {
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "proxy", "meta")
	ts, _ := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
		c.PolicyPollTimeout = 250 * time.Millisecond
	})
	registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)

	// Immediate view.
	view := decode(t, call(t, ts, http.MethodGet, "/v1/policy/voxgig-solardemo", "", nil, ""))
	if view["state"] != StatePending || view["version"] != float64(1) || view["covered"] != true {
		t.Fatalf("initial view = %v", view)
	}

	// Held to timeout when nothing changes, then answered with the
	// current view.
	start := time.Now()
	view = decode(t, call(t, ts, http.MethodGet, "/v1/policy/voxgig-solardemo?version=1", "", nil, ""))
	if elapsed := time.Since(start); elapsed < 200*time.Millisecond {
		t.Errorf("long-poll returned after %v, want ~250ms hold", elapsed)
	}
	if view["version"] != float64(1) {
		t.Errorf("timeout view version = %v, want 1", view["version"])
	}

	// Woken by approve.
	type polled struct {
		view    map[string]any
		elapsed time.Duration
	}
	done := make(chan polled, 1)
	go func() {
		s := time.Now()
		v := decode(t, call(t, ts, http.MethodGet, "/v1/policy/voxgig-solardemo?version=1", "", nil, ""))
		done <- polled{view: v, elapsed: time.Since(s)}
	}()
	time.Sleep(50 * time.Millisecond)
	if resp := call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, ""); resp.StatusCode != http.StatusOK {
		t.Fatalf("approve: %d", resp.StatusCode)
	}
	select {
	case p := <-done:
		if p.view["state"] != StateApproved || p.view["version"] != float64(2) {
			t.Errorf("woken view = %v, want approved version 2", p.view)
		}
		if p.view["secret"] != "voxgig_solardemo.apikey" {
			t.Errorf("woken view secret = %v (name only)", p.view["secret"])
		}
	case <-time.After(3 * time.Second):
		t.Fatal("long-poll never woke on approve")
	}

	// Grant revocation is a policy update too.
	call(t, ts, http.MethodDelete, "/v1/grants/voxgig-solardemo", "", nil, "")
	view = decode(t, call(t, ts, http.MethodGet, "/v1/policy/voxgig-solardemo", "", nil, ""))
	if view["version"] != float64(3) {
		t.Errorf("post-revoke version = %v, want 3", view["version"])
	}
}
