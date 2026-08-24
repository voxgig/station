package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/voxgig/station/proxy/internal/daemon"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// TestVerifyProofRejectsRedirect: §8.1's handshake is only worth
// something if the endpoint that PRODUCES the proof is the endpoint
// that will RECEIVE the bearer token. A default http.Client follows
// redirects, so an imposter squatting the configured daemon address can
// bounce /v1/health to the genuine daemon on another local address and
// relay its valid Station-Proof; verification then succeeds and the
// very next request sends the bearer token to the imposter's own URL.
func TestVerifyProofRejectsRedirect(t *testing.T) {
	var genuineHits atomic.Int64
	genuine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		genuineHits.Add(1)
		w.Header().Set("Station-Proof", daemon.Proof(testToken, r.URL.Query().Get("nonce")))
		w.WriteHeader(http.StatusOK)
	}))
	defer genuine.Close()

	imposter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, genuine.URL+r.URL.RequestURI(), http.StatusFound)
	}))
	defer imposter.Close()

	c, err := resolveClient(imposter.URL, testToken, "")
	if err != nil {
		t.Fatalf("resolveClient: %v", err)
	}
	err = c.verifyProof()
	if err == nil {
		t.Fatal("verifyProof accepted a proof relayed from another endpoint - " +
			"the bearer token would then go to the imposter")
	}
	if !strings.Contains(err.Error(), "redirect") {
		t.Errorf("error = %v, want it to name the refused redirect", err)
	}
	if n := genuineHits.Load(); n != 0 {
		t.Errorf("the genuine daemon saw %d probes: the client followed the redirect", n)
	}
}

// TestVerifyProofAcceptsTheRealDaemon is the other half: refusing
// redirects must not refuse the ordinary case.
func TestVerifyProofAcceptsTheRealDaemon(t *testing.T) {
	daemonSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Station-Proof", daemon.Proof(testToken, r.URL.Query().Get("nonce")))
		w.WriteHeader(http.StatusOK)
	}))
	defer daemonSrv.Close()

	c, err := resolveClient(daemonSrv.URL, testToken, "")
	if err != nil {
		t.Fatalf("resolveClient: %v", err)
	}
	if err := c.verifyProof(); err != nil {
		t.Fatalf("verifyProof against the token holder failed: %v", err)
	}
}
