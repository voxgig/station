package daemon

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// --- §8.5/§15: capture redaction, replayability, truncation ------------

// TestCaptureScrubInjected: after an R2-injected exchange where the
// upstream echoes the credential back (the §7 caveat: a 401 diagnostic,
// a token exchange), the secret bytes appear NOWHERE in the capture
// store - not in headers, not in bodies, not anywhere.
func TestCaptureScrubInjected(t *testing.T) {
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "proxy", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	if resp := call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, ""); resp.StatusCode != http.StatusOK {
		t.Fatalf("approve: %d", resp.StatusCode)
	}
	session, binding := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
	grant := binding["grant"].(string)

	up.respond = func(w http.ResponseWriter, r *http.Request) {
		// A hostile-ish upstream echoing the injected credential in a
		// header and the body.
		w.Header().Set("X-Echo", "seen: "+testSecret)
		w.Header().Add("Set-Cookie", "auth="+testSecret)
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprintf(w, `{"diagnostic":"bad key %s"}`, testSecret)
	}
	resp := forward(t, ts, session, map[string]string{"Station-Grant": grant},
		envelope(t, up.ts.URL+"/echo", "GET", map[string]any{
			"Authorization": "Bearer [station:voxgig-solardemo]",
		}, ""))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("forward status = %d", resp.StatusCode)
	}

	dump := srv.captures.DumpForScan()
	if strings.Contains(dump, testSecret) {
		t.Fatal("the injected secret appears in the capture store")
	}
	if !strings.Contains(dump, redactedMarker) {
		t.Error("expected redaction markers in the capture store")
	}

	entries := srv.captures.Snapshot()
	last := entries[len(entries)-1]
	if last.Depth != "full" || last.Degraded {
		t.Errorf("depth = %q degraded=%v, want full/false (proxy can scrub its own injection)", last.Depth, last.Degraded)
	}
	if got := last.ReqHeaders["Authorization"]; len(got) != 1 || got[0] != redactedMarker {
		t.Errorf("captured Authorization = %v, want [%s]", got, redactedMarker)
	}
	if !strings.Contains(last.ResBody, redactedMarker) {
		t.Errorf("captured response body should carry the redaction marker: %q", last.ResBody)
	}
	// No request body, redaction touched only headers/response: the
	// capture stays replayable (§8.5's auth-header exception).
	if !last.Replayable {
		t.Errorf("replayable = false (%s), want true", last.Reason)
	}
	if last.Status != 401 {
		t.Errorf("captured status = %d, want 401", last.Status)
	}
}

// TestCaptureScrubStationRedact: the §15 R1-attached case - the LIBRARY
// resolved the credential and named its envelope header in
// Station-Redact; the proxy scrubs it from the capture (headers AND an
// upstream body echo) while holding it only transiently.
func TestCaptureScrubStationRedact(t *testing.T) {
	const libSecret = "sk-lib-resolved-42"
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "library", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)

	up.respond = func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "echo %s back", libSecret)
	}
	resp := forward(t, ts, session,
		map[string]string{"Station-Redact": "Authorization"},
		envelope(t, up.ts.URL+"/lib", "GET", map[string]any{
			"Authorization": "Bearer " + libSecret,
		}, ""))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("forward status = %d", resp.StatusCode)
	}

	dump := srv.captures.DumpForScan()
	if strings.Contains(dump, libSecret) {
		t.Fatal("the library-resolved secret appears in the capture store")
	}

	entries := srv.captures.Snapshot()
	last := entries[len(entries)-1]
	if last.Degraded || last.Depth != "full" {
		t.Errorf("marked exchange should capture at full, got depth=%q degraded=%v", last.Depth, last.Degraded)
	}
	if !strings.Contains(last.ResBody, redactedMarker) {
		t.Errorf("response body echo not scrubbed: %q", last.ResBody)
	}
	// Redacted AUTH HEADERS are the exception (§8.5): replay restores
	// them through the credential path, so this capture is replayable.
	if !last.Replayable {
		t.Errorf("replayable = false (%s), want true - header redaction is the exception", last.Reason)
	}

	// And the value was held transiently: it never joined the broker's
	// persistent scrub set (§15: discarded unwritten after the exchange).
	for _, v := range srv.broker.heldValues() {
		if strings.Contains(v, libSecret) {
			t.Error("Station-Redact value leaked into the persistent broker set")
		}
	}
}

// TestCaptureReplayableBodyScrub: redaction that replaces REQUEST-body
// bytes makes the capture non-replayable (§8.5).
func TestCaptureReplayableBodyScrub(t *testing.T) {
	const libSecret = "sk-in-the-body-7"
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "library", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)

	resp := forward(t, ts, session,
		map[string]string{"Station-Redact": "Authorization"},
		envelope(t, up.ts.URL+"/token", "POST", map[string]any{
			"Authorization": "Bearer " + libSecret,
		}, `grant_type=refresh&token=`+libSecret))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("forward status = %d", resp.StatusCode)
	}

	entries := srv.captures.Snapshot()
	last := entries[len(entries)-1]
	if strings.Contains(last.ReqBody, libSecret) {
		t.Fatal("request body kept the secret")
	}
	if last.Replayable {
		t.Error("replayable = true, want false: redaction replaced request-body bytes")
	}
	if !strings.Contains(last.Reason, "redaction") {
		t.Errorf("reason = %q, want a redaction reason", last.Reason)
	}
}

// TestCaptureTruncation: capture-full bodies cut at the configured limit
// with the truncated marker; a truncated request body is not replayable
// while a truncated RESPONSE body alone does not matter (§8.5).
func TestCaptureTruncation(t *testing.T) {
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "library", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
		c.CaptureBodyLimit = 16
	})
	session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
	up.respond = func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, strings.Repeat("R", 40))
	}

	t.Run("request body truncated", func(t *testing.T) {
		resp := forward(t, ts, session, nil,
			envelope(t, up.ts.URL+"/big", "POST", nil, strings.Repeat("Q", 40)))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("forward status = %d", resp.StatusCode)
		}
		entries := srv.captures.Snapshot()
		last := entries[len(entries)-1]
		if !last.ReqTruncated || len(last.ReqBody) != 16 {
			t.Errorf("req: truncated=%v len=%d, want true/16", last.ReqTruncated, len(last.ReqBody))
		}
		if last.ReqBodyBytes != 40 {
			t.Errorf("reqBodyBytes = %d, want the true size 40", last.ReqBodyBytes)
		}
		if !last.ResTruncated || len(last.ResBody) != 16 || last.ResBodyBytes != 40 {
			t.Errorf("res: truncated=%v len=%d bytes=%d, want true/16/40",
				last.ResTruncated, len(last.ResBody), last.ResBodyBytes)
		}
		if last.Replayable {
			t.Error("truncated request body must not be replayable")
		}
	})

	t.Run("response truncation alone stays replayable", func(t *testing.T) {
		resp := forward(t, ts, session, nil, envelope(t, up.ts.URL+"/get", "GET", nil, ""))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("forward status = %d", resp.StatusCode)
		}
		entries := srv.captures.Snapshot()
		last := entries[len(entries)-1]
		if !last.ResTruncated {
			t.Error("response should be truncated")
		}
		if !last.Replayable {
			t.Errorf("replayable = false (%s), want true - replay re-issues the request, not the response", last.Reason)
		}
	})
}

// TestCaptureDegrade: §15's missing-marker rule - a real credential in a
// redact-list envelope header, unnamed by Station-Redact and not this
// exchange's injection, means the proxy cannot scrub bodies; capture
// degrades full -> headers and says so.
func TestCaptureDegrade(t *testing.T) {
	const unmarked = "sk-unmarked-99"
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "library", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)
	up.respond = func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "leaky echo %s", unmarked)
	}

	resp := forward(t, ts, session, nil, // no Station-Redact marker
		envelope(t, up.ts.URL+"/old-lib", "POST", map[string]any{
			"Authorization": "Bearer " + unmarked,
		}, "some request body"))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("forward status = %d", resp.StatusCode)
	}

	entries := srv.captures.Snapshot()
	last := entries[len(entries)-1]
	if last.Depth != "headers" || !last.Degraded {
		t.Fatalf("depth=%q degraded=%v, want headers/true", last.Depth, last.Degraded)
	}
	if last.ReqBody != "" || last.ResBody != "" {
		t.Error("degraded capture must not store bodies")
	}
	if strings.Contains(srv.captures.DumpForScan(), unmarked) {
		t.Fatal("unmarked credential leaked into the capture store")
	}
	st := decode(t, call(t, ts, http.MethodGet, "/v1/status", "", nil, ""))
	if got := st["captures"].(map[string]any)["degraded"].(float64); got != 1 {
		t.Errorf("status captures.degraded = %v, want 1", got)
	}
}

// --- §8.5: LRU bounds ---------------------------------------------------

func TestCaptureStoreEntryBound(t *testing.T) {
	cs := NewCaptureStore(3, 1<<30)
	for i := 0; i < 5; i++ {
		cs.Add(&CaptureEntry{ReqMethod: "GET", ReqURL: fmt.Sprintf("http://x/%d", i)})
	}
	st := cs.Stats()
	if st.Entries != 3 || st.Evicted != 2 || st.Total != 5 {
		t.Fatalf("stats = %+v, want entries 3 evicted 2 total 5", st)
	}
	snap := cs.Snapshot()
	if snap[0].ReqURL != "http://x/2" || snap[2].ReqURL != "http://x/4" {
		t.Errorf("oldest-first eviction broken: %s .. %s", snap[0].ReqURL, snap[2].ReqURL)
	}
}

func TestCaptureStoreByteBound(t *testing.T) {
	// Each entry: 172-byte body + 128 accounting overhead = 300 bytes.
	entry := func() *CaptureEntry {
		return &CaptureEntry{ReqBody: strings.Repeat("b", 172)}
	}
	cs := NewCaptureStore(100, 700)
	cs.Add(entry())
	cs.Add(entry())
	if st := cs.Stats(); st.Entries != 2 || st.Bytes != 600 || st.Evicted != 0 {
		t.Fatalf("pre-overflow stats = %+v", st)
	}
	cs.Add(entry()) // 900 > 700: evict oldest
	st := cs.Stats()
	if st.Entries != 2 || st.Bytes != 600 || st.Evicted != 1 {
		t.Fatalf("post-overflow stats = %+v, want entries 2 bytes 600 evicted 1", st)
	}
}

// TestCaptureAccountingCountsMetadata: the byte bound must charge for
// the VARIABLE metadata an entry retains, not stand a fixed estimate in
// for all of it. `Corr` in particular comes straight off a client-
// supplied Station-Corr header and is referenced for the entry's whole
// life, so a store that charges it nothing can hold far more memory
// than CaptureMaxBytes reports or enforces.
func TestCaptureAccountingCountsMetadata(t *testing.T) {
	t.Run("every retained string is charged", func(t *testing.T) {
		e := &CaptureEntry{
			T: "2026-08-24T09:00:00Z", Session: "sess-1",
			Plugin: "voxgig-solardemo", Corr: "corr-1",
			Depth: "full", ReqMethod: "POST",
		}
		want := int64(128 + len(e.T) + len(e.Session) + len(e.Plugin) +
			len(e.Corr) + len(e.Depth) + len(e.ReqMethod))
		if got := e.accounting(); got != want {
			t.Errorf("accounting = %d, want %d (the metadata strings are retained, so they count)",
				got, want)
		}
	})

	t.Run("a large corr is bounded like a body", func(t *testing.T) {
		// Each entry: 172-byte Corr + 128 fixed overhead = 300 bytes,
		// so the third overflows a 700-byte store exactly as a body of
		// the same size would.
		entry := func() *CaptureEntry { return &CaptureEntry{Corr: strings.Repeat("c", 172)} }
		cs := NewCaptureStore(100, 700)
		cs.Add(entry())
		cs.Add(entry())
		if st := cs.Stats(); st.Entries != 2 || st.Bytes != 600 || st.Evicted != 0 {
			t.Fatalf("pre-overflow stats = %+v, want entries 2 bytes 600 evicted 0", st)
		}
		cs.Add(entry())
		st := cs.Stats()
		if st.Entries != 2 || st.Bytes != 600 || st.Evicted != 1 {
			t.Fatalf("post-overflow stats = %+v, want entries 2 bytes 600 evicted 1 - "+
				"the advertised bound must be the one enforced", st)
		}
	})
}

// TestCaptureDegradeBodyCredential extends §15's missing-marker rule to
// the REQUEST BODY. Under R1-attached the proxy learns transient secret
// values only from the headers Station-Redact names, so an integration
// that carries its credential solely in the body - a token exchange is
// the ordinary case - leaves the proxy with neither a transient value
// nor a broker-held one, and `capture: full` would store the credential
// verbatim.
func TestCaptureDegradeBodyCredential(t *testing.T) {
	const bodyOnly = "sk-body-only-31"
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "library", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	session, _ := registerInstance(t, ts, "voxgig-solardemo", up.ts.URL)

	t.Run("a body-only credential degrades the capture", func(t *testing.T) {
		up.respond = func(w http.ResponseWriter, r *http.Request) {
			// The exchange's whole point: the response mints another one.
			fmt.Fprintf(w, `{"access_token":"minted-%s"}`, bodyOnly)
		}
		// No Station-Redact: nothing names the body, and no header
		// carries a credential for the header rule to catch.
		resp := forward(t, ts, session, nil,
			envelope(t, up.ts.URL+"/oauth/token", "POST", map[string]any{
				"Content-Type": "application/x-www-form-urlencoded",
			}, "grant_type=client_credentials&client_id=app&client_secret="+bodyOnly))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("forward status = %d", resp.StatusCode)
		}

		entries := srv.captures.Snapshot()
		last := entries[len(entries)-1]
		if last.Depth != "headers" || !last.Degraded {
			t.Fatalf("depth=%q degraded=%v, want headers/true", last.Depth, last.Degraded)
		}
		if last.ReqBody != "" || last.ResBody != "" {
			t.Error("a degraded capture must not store bodies")
		}
		if strings.Contains(srv.captures.DumpForScan(), bodyOnly) {
			t.Fatal("the body-only credential entered the capture store")
		}
	})

	t.Run("an ordinary body still captures at full", func(t *testing.T) {
		// The rule is a credential-SHAPE test, not a "there is a body"
		// test: degrading every POST would cost §8.5 its whole point.
		up.respond = nil
		resp := forward(t, ts, session, nil,
			envelope(t, up.ts.URL+"/planet", "POST", nil, `{"name":"pluto","mass":1}`))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("forward status = %d", resp.StatusCode)
		}
		entries := srv.captures.Snapshot()
		last := entries[len(entries)-1]
		if last.Depth != "full" || last.Degraded {
			t.Errorf("depth=%q degraded=%v, want full/false", last.Depth, last.Degraded)
		}
		if !strings.Contains(last.ReqBody, "pluto") {
			t.Errorf("captured request body = %q, want the body verbatim", last.ReqBody)
		}
	})
}
