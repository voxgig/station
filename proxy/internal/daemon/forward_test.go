package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// upstream is a recording httptest upstream.
type upstream struct {
	ts *httptest.Server

	mu   sync.Mutex
	reqs []recordedReq

	// respond configures the next responses.
	respond func(w http.ResponseWriter, r *http.Request)
}

type recordedReq struct {
	Method  string
	Path    string
	Headers http.Header
	Body    string
}

func newUpstream(t *testing.T) *upstream {
	t.Helper()
	u := &upstream{}
	u.ts = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		u.mu.Lock()
		u.reqs = append(u.reqs, recordedReq{
			Method: r.Method, Path: r.URL.Path,
			Headers: r.Header.Clone(), Body: string(body),
		})
		respond := u.respond
		u.mu.Unlock()
		if respond != nil {
			respond(w, r)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	}))
	t.Cleanup(u.ts.Close)
	return u
}

func (u *upstream) count() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return len(u.reqs)
}

func (u *upstream) last(t *testing.T) recordedReq {
	t.Helper()
	u.mu.Lock()
	defer u.mu.Unlock()
	if len(u.reqs) == 0 {
		t.Fatal("upstream received no requests")
	}
	return u.reqs[len(u.reqs)-1]
}

// registerInstance registers one instance ref with a descriptor claiming
// the given base, returning the session id and binding.
func registerInstance(t *testing.T, ts *httptest.Server, instance string, base string) (string, map[string]any) {
	t.Helper()
	desc := fmt.Sprintf(`{"station":1,"name":"Solardemo","slug":"voxgig-solardemo","base":%q}`, base)
	body := fmt.Sprintf(`{"descriptor":%s,"process":{"pid":7,"lang":"go","app":"t"},"instance":%q}`, desc, instance)
	resp := call(t, ts, http.MethodPost, "/v1/register", body, nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register: status %d", resp.StatusCode)
	}
	m := decode(t, resp)
	session, _ := m["session"].(string)
	binding, _ := m["binding"].(map[string]any)
	if session == "" || binding == nil {
		t.Fatalf("register: bad response %v", m)
	}
	return session, binding
}

// envelope builds a forward envelope body.
func envelope(t *testing.T, targetURL string, method string, headers map[string]any, body string) string {
	t.Helper()
	env := map[string]any{"url": targetURL, "method": method}
	if headers != nil {
		env["headers"] = headers
	}
	if body != "" {
		env["body"] = body
	}
	text, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	return string(text)
}

func forward(t *testing.T, ts *httptest.Server, session string, hdr map[string]string, env string) *http.Response {
	t.Helper()
	headers := map[string]string{"Station-Session": session}
	for k, v := range hdr {
		headers[k] = v
	}
	return call(t, ts, http.MethodPost, "/v1/forward", env, headers, "")
}

// --- §8.2: forward semantics -------------------------------------------

func TestForwardSemantics(t *testing.T) {
	up := newUpstream(t)
	ts := newTestProxy(t, nil)
	session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)

	t.Run("request reaches upstream; metadata rides back", func(t *testing.T) {
		up.respond = func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-One", "single")
			w.Header().Add("Set-Cookie", "a=1")
			w.Header().Add("Set-Cookie", "b=2")
			w.WriteHeader(http.StatusTeapot)
			fmt.Fprint(w, "short and stout")
		}
		env := envelope(t, up.ts.URL+"/pots?x=1", "POST", map[string]any{
			"Content-Type": "application/json",
			"X-Multi":      []any{"m1", "m2"},
		}, `{"kind":"tea"}`)
		resp := forward(t, ts, session, map[string]string{"Station-Corr": "corr-1"}, env)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("outer status = %d, want 200 (upstream status rides in Station-Status)", resp.StatusCode)
		}
		if got := resp.Header.Get("Station-Status"); got != "418" {
			t.Errorf("Station-Status = %q, want 418", got)
		}
		if got := resp.Header.Get("Station-Up-X-One"); got != "single" {
			t.Errorf("Station-Up-X-One = %q, want single", got)
		}
		// Repeats preserved (§8.2: each header individually, prefixed).
		cookies := resp.Header.Values("Station-Up-Set-Cookie")
		if len(cookies) != 2 || cookies[0] != "a=1" || cookies[1] != "b=2" {
			t.Errorf("Station-Up-Set-Cookie = %v, want [a=1 b=2]", cookies)
		}
		body, _ := io.ReadAll(resp.Body)
		if string(body) != "short and stout" {
			t.Errorf("body = %q, want raw upstream body", body)
		}

		req := up.last(t)
		if req.Method != "POST" || req.Path != "/pots" {
			t.Errorf("upstream saw %s %s", req.Method, req.Path)
		}
		if req.Body != `{"kind":"tea"}` {
			t.Errorf("upstream body = %q", req.Body)
		}
		if got := req.Headers.Values("X-Multi"); len(got) != 2 || got[0] != "m1" || got[1] != "m2" {
			t.Errorf("upstream X-Multi = %v, want [m1 m2]", got)
		}
	})

	t.Run("binary response body passes through", func(t *testing.T) {
		raw := make([]byte, 256)
		for i := range raw {
			raw[i] = byte(i)
		}
		up.respond = func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Write(raw)
		}
		resp := forward(t, ts, session, nil, envelope(t, up.ts.URL+"/bin", "GET", nil, ""))
		body, _ := io.ReadAll(resp.Body)
		if !bytes.Equal(body, raw) {
			t.Errorf("binary body corrupted: got %d bytes, want %d identical", len(body), len(raw))
		}
	})

	t.Run("3xx rides back unfollowed", func(t *testing.T) {
		before := up.count()
		up.respond = func(w http.ResponseWriter, r *http.Request) {
			// A Location off any allowlist: an automatic follow would be
			// exactly the §8.2 credential-exfiltration hazard.
			w.Header().Set("Location", "http://evil.example/next")
			w.WriteHeader(http.StatusFound)
		}
		resp := forward(t, ts, session, nil, envelope(t, up.ts.URL+"/hop", "GET", nil, ""))
		if got := resp.Header.Get("Station-Status"); got != "302" {
			t.Errorf("Station-Status = %q, want 302", got)
		}
		if got := resp.Header.Get("Station-Up-Location"); got != "http://evil.example/next" {
			t.Errorf("Station-Up-Location = %q", got)
		}
		if got := up.count() - before; got != 1 {
			t.Errorf("upstream saw %d requests, want exactly 1 (no follow)", got)
		}
	})

	t.Run("forward body limit", func(t *testing.T) {
		ts2 := newTestProxy(t, func(c *Config) { c.ForwardBodyLimit = 256 })
		s2, _ := registerInstance(t, ts2, "voxgig-solardemo", up.ts.URL)
		env := envelope(t, up.ts.URL, "POST", nil, strings.Repeat("z", 512))
		resp := forward(t, ts2, s2, nil, env)
		if resp.StatusCode != http.StatusRequestEntityTooLarge {
			t.Fatalf("status = %d, want 413", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeBodyLimit {
			t.Errorf("code = %q, want %q", got, CodeBodyLimit)
		}
	})

	t.Run("envelope validation", func(t *testing.T) {
		cases := []struct {
			name string
			body string
		}{
			{"not json", "nope"},
			{"relative url", `{"url":"/only/path"}`},
			{"bad scheme", `{"url":"ftp://x.example/f"}`},
			{"no host", `{"url":"http://"}`},
			{"bad header value", `{"url":"http://h.example","headers":{"X":42}}`},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				resp := forward(t, ts, session, nil, c.body)
				if resp.StatusCode != http.StatusBadRequest {
					t.Fatalf("status = %d, want 400", resp.StatusCode)
				}
				if got := errCode(t, resp); got != CodeForwardInvalid {
					t.Errorf("code = %q, want %q", got, CodeForwardInvalid)
				}
			})
		}
	})

	t.Run("station-plugin mismatch", func(t *testing.T) {
		resp := forward(t, ts, session, map[string]string{"Station-Plugin": "other$x"},
			envelope(t, up.ts.URL, "GET", nil, ""))
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeForwardInvalid {
			t.Errorf("code = %q, want %q", got, CodeForwardInvalid)
		}
	})

	t.Run("unknown session", func(t *testing.T) {
		resp := forward(t, ts, "deadbeef", nil, envelope(t, up.ts.URL, "GET", nil, ""))
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeNoSession {
			t.Errorf("code = %q, want %q", got, CodeNoSession)
		}
	})

	t.Run("upstream unreachable", func(t *testing.T) {
		// A port nothing listens on: the upstream never answers, the
		// error is structured, and no panic reaches the client.
		resp := forward(t, ts, session, nil, envelope(t, "http://127.0.0.1:1/void", "GET", nil, ""))
		if resp.StatusCode != http.StatusBadGateway {
			t.Fatalf("status = %d, want 502", resp.StatusCode)
		}
		if got := errCode(t, resp); got != CodeUpstream {
			t.Errorf("code = %q, want %q", got, CodeUpstream)
		}
	})
}
