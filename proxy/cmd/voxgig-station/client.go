// Client-side plumbing for the operator verbs (status, approve, tap):
// discovery, the §8.1 proof-of-token handshake, and authenticated
// requests. The daemon owns all state - every verb is a thin skin over
// the wire API, never a direct file write.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/voxgig/station/proxy/internal/daemon"
)

const defaultDaemonURL = "http://127.0.0.1:8299"

// daemonDown wraps a connection-level failure so verbs can tell "the
// daemon is not running" apart from a protocol error and say what to do.
type daemonDown struct {
	base string
	err  error
}

func (e *daemonDown) Error() string {
	return fmt.Sprintf("cannot reach the station daemon at %s (%v)\n"+
		"The daemon owns all state - start it with:\n\n  voxgig-station run\n\n"+
		"then re-run this command.", e.base, e.err)
}

type client struct {
	base  string
	token string
	http  *http.Client
}

// clientFlags registers the shared verb flags on fs.
func clientFlags(fs *flag.FlagSet) (urlFlag, tokenFlag, tokenFileFlag *string) {
	urlFlag = fs.String("url", "", "daemon URL (default: VOXGIG_STATION_URL, else "+defaultDaemonURL+")")
	tokenFlag = fs.String("token", "", "bearer token (default: read the token file)")
	tokenFileFlag = fs.String("token-file", "", "token file path (default ~/.voxgig/station/token)")
	return urlFlag, tokenFlag, tokenFileFlag
}

// resolveClient builds the daemon client per §8.1's discovery order:
// the explicit --url flag, else VOXGIG_STATION_URL, else the default
// loopback address. The token comes from --token, else the token file
// (which only the daemon creates - the client never writes it).
func resolveClient(urlFlag string, tokenFlag string, tokenFileFlag string) (*client, error) {
	base := urlFlag
	if base == "" {
		base = os.Getenv("VOXGIG_STATION_URL")
	}
	if base == "" {
		base = defaultDaemonURL
	}
	base = strings.TrimRight(base, "/")
	u, err := url.Parse(base)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("daemon URL must be absolute http(s), got %q", base)
	}

	token := tokenFlag
	if token == "" {
		path := tokenFileFlag
		if path == "" {
			path, err = daemon.DefaultTokenPath()
			if err != nil {
				return nil, err
			}
		}
		text, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf(
				"cannot read the token file %s (the daemon creates it on first run): %w", path, err)
		}
		token = strings.TrimSpace(string(text))
		if token == "" {
			return nil, fmt.Errorf("token file %s is empty", path)
		}
	}

	return &client{base: base, token: token, http: &http.Client{}}, nil
}

// verifyProof performs the §8.1 challenge-response BEFORE any bearer
// token is sent: a fixed loopback port is not the Docker-socket model -
// any local user can bind it first - so the client sends a nonce on the
// exempt health endpoint and checks Station-Proof against its own
// HMAC. A process that cannot produce the proof does not hold the 0600
// token file and is treated as an imposter; per §14 that reads exactly
// like absence.
func (c *client) verifyProof() error {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Errorf("cannot generate nonce: %w", err)
	}
	nonce := hex.EncodeToString(raw)

	resp, err := c.http.Get(c.base + "/v1/health?nonce=" + nonce)
	if err != nil {
		return &daemonDown{base: c.base, err: err}
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("health probe on %s returned %d", c.base, resp.StatusCode)
	}
	proof := resp.Header.Get("Station-Proof")
	want := daemon.Proof(c.token, nonce)
	if subtle.ConstantTimeCompare([]byte(proof), []byte(want)) != 1 {
		return fmt.Errorf(
			"proof-of-token FAILED for %s: the listening process does not hold the token file - "+
				"treating it as an imposter (§8.1); nothing sensitive was sent", c.base)
	}
	return nil
}

// do issues one authenticated request. verifyProof must have succeeded
// first (the §8.1 ordering: proof precedes the bearer token).
func (c *client) do(method string, path string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequest(method, c.base+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Station-Protocol", "1")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, &daemonDown{base: c.base, err: err}
	}
	return resp, nil
}

// decodeOrError reads a JSON response, turning the structured error
// shape into a Go error carrying "code: message".
func decodeOrError(resp *http.Response) (map[string]any, error) {
	defer resp.Body.Close()
	text, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(text, &m); err != nil {
		return nil, fmt.Errorf("daemon returned %d with a non-JSON body", resp.StatusCode)
	}
	if e, is := m["error"].(map[string]any); is {
		code, _ := e["code"].(string)
		message, _ := e["message"].(string)
		return nil, fmt.Errorf("%s: %s", code, message)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("daemon returned %d", resp.StatusCode)
	}
	return m, nil
}

// jsonEncoder is the shared indenting encoder for verb output.
func jsonEncoder(w io.Writer) *json.Encoder {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc
}
