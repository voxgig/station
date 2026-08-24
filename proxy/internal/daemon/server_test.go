package daemon

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Unix(1_700_000_000, 0)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// newTestProxy stands up the daemon behind httptest, with the Host
// allowlist seeded from the real listener address (the same contract
// main.go follows: Config.Listen is the bound address).
func newTestProxy(t *testing.T, mut func(*Config)) *httptest.Server {
	t.Helper()
	ts, _ := newTestProxyServer(t, mut)
	return ts
}

// newTestProxyServer additionally exposes the *Server for white-box
// assertions (the capture store's "secret bytes appear nowhere"
// guarantee is checked against the store itself).
func newTestProxyServer(t *testing.T, mut func(*Config)) (*httptest.Server, *Server) {
	t.Helper()
	ts := httptest.NewUnstartedServer(nil)
	cfg := Config{Listen: ts.Listener.Addr().String()}
	if mut != nil {
		mut(&cfg)
	}
	srv, err := NewServer(cfg, testToken)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	ts.Config.Handler = srv
	ts.Start()
	t.Cleanup(ts.Close)
	return ts, srv
}

// call issues one request with valid protocol + auth headers by default;
// hdr entries override (an empty value deletes the header). hostOverride
// replaces the HTTP Host.
func call(t *testing.T, ts *httptest.Server, method, path, body string, hdr map[string]string, hostOverride string) *http.Response {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, ts.URL+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Station-Protocol", "1")
	req.Header.Set("Authorization", "Bearer "+testToken)
	for k, v := range hdr {
		if v == "" {
			req.Header.Del(k)
		} else {
			req.Header.Set(k, v)
		}
	}
	if hostOverride != "" {
		req.Host = hostOverride
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func decode(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return m
}

// errCode asserts the one structured error shape and returns its code.
func errCode(t *testing.T, resp *http.Response) string {
	t.Helper()
	m := decode(t, resp)
	e, ok := m["error"].(map[string]any)
	if !ok {
		t.Fatalf("error response missing {error:{...}} shape: %v", m)
	}
	code, _ := e["code"].(string)
	if code == "" {
		t.Fatalf("error response missing code: %v", m)
	}
	if msg, _ := e["message"].(string); msg == "" {
		t.Fatalf("error response missing message: %v", m)
	}
	return code
}

func register(t *testing.T, ts *httptest.Server, descriptor string) string {
	t.Helper()
	body := fmt.Sprintf(`{"descriptor":%s,"process":{"pid":42,"lang":"go","app":"testapp"}}`, descriptor)
	resp := call(t, ts, http.MethodPost, "/v1/register", body, nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register: status %d", resp.StatusCode)
	}
	m := decode(t, resp)
	session, _ := m["session"].(string)
	if session == "" {
		t.Fatalf("register: no session in %v", m)
	}
	return session
}

// --- §8.1: proof-of-token ----------------------------------------------

func TestHealthProofOfToken(t *testing.T) {
	ts := newTestProxy(t, nil)

	t.Run("proof matches client-side HMAC", func(t *testing.T) {
		nonce := "client-nonce-123"
		resp := call(t, ts, http.MethodGet, "/v1/health?nonce="+nonce, "",
			map[string]string{"Authorization": "", "Station-Protocol": ""}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status %d, want 200", resp.StatusCode)
		}
		mac := hmac.New(sha256.New, []byte(testToken))
		mac.Write([]byte(nonce))
		want := hex.EncodeToString(mac.Sum(nil))
		if got := resp.Header.Get("Station-Proof"); got != want {
			t.Errorf("Station-Proof = %q, want %q", got, want)
		}
		m := decode(t, resp)
		if m["ok"] != true {
			t.Errorf("health body = %v, want ok:true", m)
		}
		if m["protocol"] != float64(1) {
			t.Errorf("health protocol = %v, want 1", m["protocol"])
		}
	})

	t.Run("no nonce, no proof header", func(t *testing.T) {
		resp := call(t, ts, http.MethodGet, "/v1/health", "",
			map[string]string{"Authorization": ""}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status %d, want 200", resp.StatusCode)
		}
		if got := resp.Header.Get("Station-Proof"); got != "" {
			t.Errorf("unexpected Station-Proof %q without a nonce", got)
		}
	})

	t.Run("health leaks nothing sensitive", func(t *testing.T) {
		resp := call(t, ts, http.MethodGet, "/v1/health?nonce=n", "",
			map[string]string{"Authorization": ""}, "")
		b, _ := io.ReadAll(resp.Body)
		if strings.Contains(string(b), testToken) {
			t.Error("health body contains the token")
		}
		if resp.Header.Get("Station-Proof") == testToken {
			t.Error("proof header is the raw token")
		}
	})
}

// --- §8.1: bearer token ------------------------------------------------

func TestAuth(t *testing.T) {
	ts := newTestProxy(t, nil)

	cases := []struct {
		name       string
		auth       string // "" deletes the header
		wantStatus int
		wantCode   string
	}{
		{"valid token", "Bearer " + testToken, http.StatusOK, ""},
		{"missing header", "", http.StatusUnauthorized, CodeTokenAllow},
		{"wrong token", "Bearer not-the-token", http.StatusUnauthorized, CodeTokenAllow},
		{"empty bearer", "Bearer ", http.StatusUnauthorized, CodeTokenAllow},
		{"wrong scheme", "Basic " + testToken, http.StatusUnauthorized, CodeTokenAllow},
		{"raw token no scheme", testToken, http.StatusUnauthorized, CodeTokenAllow},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resp := call(t, ts, http.MethodGet, "/v1/status", "",
				map[string]string{"Authorization": c.auth}, "")
			if resp.StatusCode != c.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, c.wantStatus)
			}
			if c.wantCode != "" {
				if got := errCode(t, resp); got != c.wantCode {
					t.Errorf("code = %q, want %q", got, c.wantCode)
				}
			}
		})
	}
}

// --- §8.6: protocol version --------------------------------------------

func TestProtocolVersion(t *testing.T) {
	ts := newTestProxy(t, nil)

	cases := []struct {
		name       string
		path       string
		protocol   string // "" deletes the header
		wantStatus int
		wantCode   string
	}{
		{"v1 accepted", "/v1/status", "1", http.StatusOK, ""},
		{"v2 rejected", "/v1/status", "2", http.StatusBadRequest, CodeProtocol},
		{"v0 rejected", "/v1/status", "0", http.StatusBadRequest, CodeProtocol},
		{"garbage rejected", "/v1/status", "one", http.StatusBadRequest, CodeProtocol},
		{"missing rejected", "/v1/status", "", http.StatusBadRequest, CodeProtocol},
		// /v1/health is the probe endpoint: version validated when
		// present, not required (§8.1).
		{"health without header", "/v1/health", "", http.StatusOK, ""},
		{"health with v1", "/v1/health", "1", http.StatusOK, ""},
		{"health with v9", "/v1/health", "9", http.StatusBadRequest, CodeProtocol},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resp := call(t, ts, http.MethodGet, c.path, "",
				map[string]string{"Station-Protocol": c.protocol}, "")
			if resp.StatusCode != c.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, c.wantStatus)
			}
			if c.wantCode != "" {
				if got := errCode(t, resp); got != c.wantCode {
					t.Errorf("code = %q, want %q", got, c.wantCode)
				}
			}
		})
	}
}

// --- §8.1: Host / Origin (DNS-rebinding hardening) ---------------------

func TestHostOriginValidation(t *testing.T) {
	ts := newTestProxy(t, nil)
	port := ts.Listener.Addr().(interface{ String() string }).String()
	_, portOnly, _ := strings.Cut(port, ":")

	cases := []struct {
		name       string
		host       string // "" keeps the default (the real listener address)
		origin     string
		wantStatus int
	}{
		{"default host, no origin", "", "", http.StatusOK},
		{"localhost with port", "localhost:" + portOnly, "", http.StatusOK},
		{"bare localhost", "localhost", "", http.StatusOK},
		{"bare loopback ip", "127.0.0.1", "", http.StatusOK},
		{"rebound dns name", "evil.example.com", "", http.StatusForbidden},
		{"rebound with port", "evil.example.com:" + portOnly, "", http.StatusForbidden},
		{"non-loopback ip", "10.0.0.5:" + portOnly, "", http.StatusForbidden},
		{"self origin", "", "http://127.0.0.1:" + portOnly, http.StatusOK},
		{"localhost origin", "", "http://localhost:" + portOnly, http.StatusOK},
		{"cross origin", "", "http://evil.example.com", http.StatusForbidden},
		{"local page other port", "", "http://localhost:3000", http.StatusForbidden},
		{"null origin", "", "null", http.StatusForbidden},
		{"file origin", "", "file:///etc/passwd", http.StatusForbidden},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hdr := map[string]string{}
			if c.origin != "" {
				hdr["Origin"] = c.origin
			}
			resp := call(t, ts, http.MethodGet, "/v1/status", "", hdr, c.host)
			if resp.StatusCode != c.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, c.wantStatus)
			}
			if c.wantStatus == http.StatusForbidden {
				if got := errCode(t, resp); got != CodeOriginAllow {
					t.Errorf("code = %q, want %q", got, CodeOriginAllow)
				}
			}
		})
	}

	t.Run("health is host-checked too", func(t *testing.T) {
		resp := call(t, ts, http.MethodGet, "/v1/health", "",
			map[string]string{"Authorization": ""}, "evil.example.com")
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", resp.StatusCode)
		}
	})
}

// --- §8.2/§8.3: register + session lifecycle ---------------------------

func TestRegisterValidation(t *testing.T) {
	ts := newTestProxy(t, nil)

	cases := []struct {
		name     string
		body     string
		wantCode string
	}{
		{"not json", "nope", CodeRegisterInvalid},
		{"json array", "[1,2]", CodeRegisterInvalid},
		{"missing descriptor", "{}", CodeRegisterInvalid},
		{"null descriptor", `{"descriptor":null}`, CodeRegisterInvalid},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resp := call(t, ts, http.MethodPost, "/v1/register", c.body, nil, "")
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", resp.StatusCode)
			}
			if got := errCode(t, resp); got != c.wantCode {
				t.Errorf("code = %q, want %q", got, c.wantCode)
			}
		})
	}
}

func TestSessionLifecycle(t *testing.T) {
	ts := newTestProxy(t, nil)

	// Register: the descriptor is stored verbatim and parks in "pending"
	// (§8.3 - no proxy-side policy authority in this phase).
	body := `{"descriptor":{"station":1,"name":"Solardemo","slug":"voxgig-solardemo","base":"https://api.solar.example.com"},` +
		`"process":{"pid":42,"lang":"go","app":"testapp"},"identity":{"org":"acme"}}`
	resp := call(t, ts, http.MethodPost, "/v1/register", body, nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register status = %d", resp.StatusCode)
	}
	m := decode(t, resp)
	session, _ := m["session"].(string)
	if session == "" {
		t.Fatal("no session id")
	}
	binding, ok := m["binding"].(map[string]any)
	if !ok {
		t.Fatalf("no binding in %v", m)
	}
	if binding["state"] != StatePending {
		t.Errorf("binding.state = %v, want %q", binding["state"], StatePending)
	}
	if binding["capture"] != "meta" {
		t.Errorf("binding.capture = %v, want meta", binding["capture"])
	}
	if ttl, _ := binding["ttlSeconds"].(float64); ttl <= 0 {
		t.Errorf("binding.ttlSeconds = %v, want > 0", binding["ttlSeconds"])
	}

	// Status shows the registration: plugin label from the descriptor
	// slug, self-reported process identity, pending state.
	resp = call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
	st := decode(t, resp)
	sessions, _ := st["sessions"].([]any)
	if len(sessions) != 1 {
		t.Fatalf("status sessions = %d, want 1", len(sessions))
	}
	sv := sessions[0].(map[string]any)
	if sv["session"] != session {
		t.Errorf("status session id = %v, want %v", sv["session"], session)
	}
	if sv["plugin"] != "voxgig-solardemo" {
		t.Errorf("status plugin = %v, want voxgig-solardemo", sv["plugin"])
	}
	if sv["state"] != StatePending {
		t.Errorf("status state = %v, want pending", sv["state"])
	}
	proc := sv["process"].(map[string]any)
	if proc["pid"] != float64(42) || proc["lang"] != "go" || proc["app"] != "testapp" {
		t.Errorf("status process = %v", proc)
	}
	plugins, _ := st["plugins"].([]any)
	if len(plugins) != 1 {
		t.Fatalf("status plugins = %d, want 1", len(plugins))
	}
	pv := plugins[0].(map[string]any)
	if pv["plugin"] != "voxgig-solardemo" || pv["state"] != StatePending {
		t.Errorf("status plugins[0] = %v", pv)
	}

	// DELETE /v1/session ends it; a second delete is idempotent (§3.4).
	resp = call(t, ts, http.MethodDelete, "/v1/session", "",
		map[string]string{"Station-Session": session}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("delete status = %d", resp.StatusCode)
	}
	if d := decode(t, resp); d["removed"] != true {
		t.Errorf("first delete removed = %v, want true", d["removed"])
	}
	resp = call(t, ts, http.MethodDelete, "/v1/session", "",
		map[string]string{"Station-Session": session}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("second delete status = %d", resp.StatusCode)
	}
	if d := decode(t, resp); d["removed"] != false {
		t.Errorf("second delete removed = %v, want false", d["removed"])
	}

	// Gone from status.
	resp = call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
	st = decode(t, resp)
	if sessions, _ := st["sessions"].([]any); len(sessions) != 0 {
		t.Errorf("status sessions after delete = %d, want 0", len(sessions))
	}

	// Missing header is a 400.
	resp = call(t, ts, http.MethodDelete, "/v1/session", "", nil, "")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("no-header delete status = %d, want 400", resp.StatusCode)
	}
	if got := errCode(t, resp); got != CodeNoSession {
		t.Errorf("code = %q, want %q", got, CodeNoSession)
	}
}

func TestSessionExpiry(t *testing.T) {
	clk := newFakeClock()
	ts := newTestProxy(t, func(c *Config) {
		c.Now = clk.Now
		c.SessionTTL = time.Minute
	})

	session := register(t, ts, `{"slug":"voxgig-solardemo"}`)

	// Alive inside the TTL: an events batch touches liveness (§3.4).
	clk.Advance(50 * time.Second)
	resp := call(t, ts, http.MethodPost, "/v1/events", `{"kind":"op"}`+"\n",
		map[string]string{"Station-Session": session}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("in-TTL events status = %d", resp.StatusCode)
	}

	// The touch reset the window; another 50s is still alive.
	clk.Advance(50 * time.Second)
	resp = call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
	if st := decode(t, resp); len(st["sessions"].([]any)) != 1 {
		t.Fatal("session should still be alive after liveness touch")
	}

	// Past the TTL: expired reads exactly like unknown - re-register.
	clk.Advance(2 * time.Minute)
	resp = call(t, ts, http.MethodPost, "/v1/events", `{"kind":"op"}`+"\n",
		map[string]string{"Station-Session": session}, "")
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expired events status = %d, want 404", resp.StatusCode)
	}
	if got := errCode(t, resp); got != CodeNoSession {
		t.Errorf("code = %q, want %q", got, CodeNoSession)
	}

	// And status shows no ghosts (§3.4).
	resp = call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
	if st := decode(t, resp); len(st["sessions"].([]any)) != 0 {
		t.Error("expired session still listed in status")
	}
}

// --- §8.2/§8.5: events ingest + ring bounds ----------------------------

func TestEventsIngest(t *testing.T) {
	ts := newTestProxy(t, nil)

	t.Run("missing session header", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/events", `{"kind":"op"}`, nil, "")
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeNoSession {
			t.Errorf("code = %q, want %q", got, CodeNoSession)
		}
	})

	t.Run("unknown session", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/events", `{"kind":"op"}`,
			map[string]string{"Station-Session": "deadbeef"}, "")
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeNoSession {
			t.Errorf("code = %q, want %q", got, CodeNoSession)
		}
	})

	t.Run("batch with malformed lines", func(t *testing.T) {
		session := register(t, ts, `{"slug":"voxgig-solardemo"}`)
		batch := strings.Join([]string{
			`{"t":1,"plugin":"voxgig-solardemo","kind":"op"}`,
			``, // blank lines are skipped, not counted
			`not json at all`,
			`{"t":2,"plugin":"voxgig-solardemo","kind":"http"}`,
			`[3,4]`, // an event is a JSON object
		}, "\n") + "\n"
		resp := call(t, ts, http.MethodPost, "/v1/events", batch,
			map[string]string{"Station-Session": session}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		m := decode(t, resp)
		if m["accepted"] != float64(2) || m["invalid"] != float64(2) {
			t.Errorf("accepted/invalid = %v/%v, want 2/2", m["accepted"], m["invalid"])
		}

		// Ring fill and session event count are visible in status.
		resp = call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
		st := decode(t, resp)
		ev := st["events"].(map[string]any)
		ring := ev["ring"].(map[string]any)
		if ring["size"] != float64(2) || ring["total"] != float64(2) || ring["dropped"] != float64(0) {
			t.Errorf("ring = %v, want size 2 total 2 dropped 0", ring)
		}
		if ev["invalid"] != float64(2) {
			t.Errorf("invalid counter = %v, want 2", ev["invalid"])
		}
		sv := st["sessions"].([]any)[0].(map[string]any)
		if sv["events"] != float64(2) {
			t.Errorf("session events = %v, want 2", sv["events"])
		}
	})
}

func TestEventsRingBoundEviction(t *testing.T) {
	ts := newTestProxy(t, func(c *Config) { c.RingCapacity = 4 })
	session := register(t, ts, `{"slug":"voxgig-solardemo"}`)

	var lines []string
	for i := 0; i < 6; i++ {
		lines = append(lines, fmt.Sprintf(`{"t":%d,"kind":"op"}`, i))
	}
	resp := call(t, ts, http.MethodPost, "/v1/events", strings.Join(lines, "\n"),
		map[string]string{"Station-Session": session}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if m := decode(t, resp); m["accepted"] != float64(6) {
		t.Fatalf("accepted = %v, want 6", m["accepted"])
	}

	// §8.5/§6: bounded ring, overflow drops oldest, drops visible.
	resp = call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
	st := decode(t, resp)
	ring := st["events"].(map[string]any)["ring"].(map[string]any)
	if ring["capacity"] != float64(4) || ring["size"] != float64(4) ||
		ring["total"] != float64(6) || ring["dropped"] != float64(2) {
		t.Errorf("ring = %v, want capacity 4 size 4 total 6 dropped 2", ring)
	}
	bounds := st["bounds"].(map[string]any)
	if bounds["ringCapacity"] != float64(4) {
		t.Errorf("bounds.ringCapacity = %v, want 4", bounds["ringCapacity"])
	}
}

func TestBodyLimits(t *testing.T) {
	t.Run("register over limit", func(t *testing.T) {
		ts := newTestProxy(t, func(c *Config) { c.RegisterBodyLimit = 128 })
		big := `{"descriptor":{"pad":"` + strings.Repeat("x", 256) + `"}}`
		resp := call(t, ts, http.MethodPost, "/v1/register", big, nil, "")
		if resp.StatusCode != http.StatusRequestEntityTooLarge {
			t.Fatalf("status = %d, want 413", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeBodyLimit {
			t.Errorf("code = %q, want %q", got, CodeBodyLimit)
		}
	})

	t.Run("events batch over limit", func(t *testing.T) {
		ts := newTestProxy(t, func(c *Config) { c.EventsBodyLimit = 256 })
		session := register(t, ts, `{"slug":"voxgig-solardemo"}`)
		var lines []string
		for i := 0; i < 20; i++ {
			lines = append(lines, fmt.Sprintf(`{"t":%d,"pad":"%s"}`, i, strings.Repeat("y", 40)))
		}
		resp := call(t, ts, http.MethodPost, "/v1/events", strings.Join(lines, "\n"),
			map[string]string{"Station-Session": session}, "")
		if resp.StatusCode != http.StatusRequestEntityTooLarge {
			t.Fatalf("status = %d, want 413", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeBodyLimit {
			t.Errorf("code = %q, want %q", got, CodeBodyLimit)
		}
	})
}

// --- routing -----------------------------------------------------------

func TestRouting(t *testing.T) {
	ts := newTestProxy(t, nil)

	cases := []struct {
		name       string
		method     string
		path       string
		wantStatus int
	}{
		{"unknown path", http.MethodGet, "/v1/nope", http.StatusNotFound},
		{"root", http.MethodGet, "/", http.StatusNotFound},
		{"status wrong method", http.MethodPost, "/v1/status", http.StatusMethodNotAllowed},
		{"register wrong method", http.MethodGet, "/v1/register", http.StatusMethodNotAllowed},
		{"session wrong method", http.MethodPost, "/v1/session", http.StatusMethodNotAllowed},
		{"health wrong method", http.MethodPost, "/v1/health", http.StatusMethodNotAllowed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resp := call(t, ts, c.method, c.path, "", nil, "")
			if resp.StatusCode != c.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, c.wantStatus)
			}
			if got := errCode(t, resp); got != CodeNoRoute {
				t.Errorf("code = %q, want %q", got, CodeNoRoute)
			}
		})
	}
}

// --- §8.2: tap streaming -----------------------------------------------

// tapStream opens GET /v1/tap and returns a channel of NDJSON lines.
func tapStream(t *testing.T, ts *httptest.Server, query string) (<-chan string, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/tap"+query, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Station-Protocol", "1")
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("tap status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/x-ndjson" {
		t.Errorf("tap content-type = %q, want application/x-ndjson", ct)
	}
	lines := make(chan string, 16)
	go func() {
		defer resp.Body.Close()
		defer close(lines)
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
	}()
	t.Cleanup(cancel)
	return lines, cancel
}

func expectLine(t *testing.T, lines <-chan string) string {
	t.Helper()
	select {
	case l, ok := <-lines:
		if !ok {
			t.Fatal("tap stream closed early")
		}
		return l
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for tap line")
		return ""
	}
}

func expectNoLine(t *testing.T, lines <-chan string) {
	t.Helper()
	select {
	case l, ok := <-lines:
		if ok {
			t.Fatalf("unexpected tap line %q", l)
		}
	case <-time.After(150 * time.Millisecond):
	}
}

func TestTapStreaming(t *testing.T) {
	ts := newTestProxy(t, nil)
	session := register(t, ts, `{"slug":"voxgig-solardemo"}`)

	all, cancelAll := tapStream(t, ts, "")
	filtered, _ := tapStream(t, ts, "?plugin=alpha")

	post := func(batch string) {
		resp := call(t, ts, http.MethodPost, "/v1/events", batch,
			map[string]string{"Station-Session": session}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("events status = %d", resp.StatusCode)
		}
	}

	evAlpha := `{"t":1,"plugin":"alpha","kind":"op"}`
	evBeta := `{"t":2,"plugin":"beta","kind":"http"}`
	post(evAlpha + "\n" + evBeta + "\n")

	// The unfiltered tap sees both, in order, verbatim.
	if got := expectLine(t, all); got != evAlpha {
		t.Errorf("tap line 1 = %q, want %q", got, evAlpha)
	}
	if got := expectLine(t, all); got != evBeta {
		t.Errorf("tap line 2 = %q, want %q", got, evBeta)
	}

	// The filtered tap sees only its instance (§6: tap [plugin]).
	if got := expectLine(t, filtered); got != evAlpha {
		t.Errorf("filtered tap line = %q, want %q", got, evAlpha)
	}
	expectNoLine(t, filtered)

	// Tap subscribers are visible in status.
	resp := call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
	st := decode(t, resp)
	if subs := st["events"].(map[string]any)["tapSubscribers"]; subs != float64(2) {
		t.Errorf("tapSubscribers = %v, want 2", subs)
	}

	// Disconnecting a tap unsubscribes it; publishing afterwards still
	// works and reaches the remaining subscriber.
	cancelAll()
	waitFor(t, func() bool {
		resp := call(t, ts, http.MethodGet, "/v1/status", "", nil, "")
		st := decode(t, resp)
		return st["events"].(map[string]any)["tapSubscribers"] == float64(1)
	})
	post(evAlpha + "\n")
	if got := expectLine(t, filtered); got != evAlpha {
		t.Errorf("post-disconnect filtered line = %q, want %q", got, evAlpha)
	}
}

// waitFor polls cond until true or the deadline trips.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition never became true")
}

// TestRouteRefWithSlash: an instance NAME is a package-ish specifier and
// explicitly admits `/` (§6.1's `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$` -
// `@scope/pkg` is a valid ref), which the CLI duly sends percent-
// encoded. Go decodes `%2F` into r.URL.Path before any handler runs, so
// a router that looks for `/` there cannot tell a segment separator
// from an escaped character and makes every scoped ref permanently
// unaddressable: approve, policy polling and grant revocation could
// never name one.
func TestRouteRefWithSlash(t *testing.T) {
	up := newUpstream(t)
	ts := newTestProxy(t, nil)

	const ref = "@scope/pkg"
	escaped := url.PathEscape(ref) // @scope%2Fpkg
	registerInstance(t, ts, ref, up.ts.URL)

	t.Run("approve addresses the ref", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/approve/"+escaped, "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		approval := decode(t, resp)["approval"].(map[string]any)
		if approval["ref"] != ref {
			t.Errorf("approved ref = %v, want %q (the escape must be undone, not kept)",
				approval["ref"], ref)
		}
	})

	t.Run("policy addresses the ref", func(t *testing.T) {
		view := decode(t, call(t, ts, http.MethodGet, "/v1/policy/"+escaped, "", nil, ""))
		if view["ref"] != ref || view["state"] != StateApproved {
			t.Errorf("policy view = %v, want approved %q", view, ref)
		}
	})

	t.Run("grant revocation addresses the ref", func(t *testing.T) {
		resp := call(t, ts, http.MethodDelete, "/v1/grants/"+escaped, "", nil, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
	})

	t.Run("a literal slash is still a path separator", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/approve/"+ref, "", nil, "")
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("status = %d, want 404 - an unescaped `/` is not part of the ref",
				resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeNoRoute {
			t.Errorf("code = %q, want %q", got, CodeNoRoute)
		}
	})
}
