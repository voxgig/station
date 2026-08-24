package daemon

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

// acceptedProtocols implements §8.6's acceptance policy: the proxy
// accepts wire protocol versions N and N-1 and rejects unknown versions
// with a structured station_protocol error the library surfaces. v1 is
// the first protocol, so N-1 does not exist yet and the accepted set is
// {1}; when protocol 2 ships this becomes {"2", "1"}, and a later drop
// of 1 waits until 3.
var acceptedProtocols = map[string]bool{"1": true}

// Server is the control-plane core: token-authenticated HTTP/1.1 + JSON
// on loopback (§8.1), sessions and registration (§8.2/§8.3), event
// ingest into a bounded ring, live tap, and status. The data plane
// (/v1/forward), grants, policy long-poll and the MCP surface arrive in
// later phases; the seams they land on are the Sessions store, the Ring
// snapshot, and this router.
type Server struct {
	cfg      Config
	token    string
	start    time.Time
	ring     *Ring
	hub      *Hub
	sessions *Sessions

	// allowedHosts is the §8.1 DNS-rebinding allowlist, derived from the
	// bound address: exact Host header values (and Origin authorities)
	// this daemon answers to.
	allowedHosts map[string]bool

	invalidEvents atomic.Uint64
}

// NewServer builds the daemon handler. cfg.Listen must be the actual
// bound address (it seeds the Host/Origin allowlist).
func NewServer(cfg Config, token string) *Server {
	cfg = cfg.withDefaults()
	s := &Server{
		cfg:          cfg,
		token:        token,
		start:        cfg.Now(),
		ring:         NewRing(cfg.RingCapacity),
		hub:          NewHub(cfg.TapBuffer),
		sessions:     NewSessions(cfg.SessionTTL, cfg.Now),
		allowedHosts: allowedHostSet(cfg.Listen),
	}
	return s
}

// allowedHostSet computes the exact Host values a request may carry. A
// loopback bind answers to the three conventional loopback names on the
// bound port (with and without the port - some clients omit it); any
// other bind answers to its own host only. Everything else is treated as
// a DNS-rebinding attempt (§8.1).
func allowedHostSet(listen string) map[string]bool {
	allowed := map[string]bool{}
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		host, port = listen, ""
	}
	names := []string{host}
	if isLoopbackHost(host) {
		names = []string{"127.0.0.1", "localhost", "::1"}
	}
	for _, n := range names {
		bare := n
		if strings.Contains(n, ":") {
			bare = "[" + n + "]" // IPv6 literal in a Host header is bracketed
		}
		allowed[strings.ToLower(bare)] = true
		if port != "" {
			allowed[strings.ToLower(net.JoinHostPort(n, port))] = true
		}
	}
	return allowed
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

func (s *Server) hostAllowed(hostHeader string) bool {
	return s.allowedHosts[strings.ToLower(hostHeader)]
}

// originAllowed accepts an absent Origin (non-browser clients), and a
// present one only when it names this daemon itself over http(s). The
// browser is not an expected client of the control plane in v1, so any
// cross-origin page - the classic loopback-daemon CSRF/DNS-rebinding
// vector - is rejected (§8.1; the MCP endpoint inherits this per the MCP
// spec when it lands).
func (s *Server) originAllowed(origin string) bool {
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return false
	}
	return s.allowedHosts[strings.ToLower(u.Host)]
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// §8.1 hardening first, on every request including /v1/health: a
	// rebound DNS name or a hostile page's fetch never reaches a handler.
	if !s.hostAllowed(r.Host) {
		writeError(w, http.StatusForbidden, CodeOriginAllow,
			fmt.Sprintf("unexpected Host %q", r.Host))
		return
	}
	if !s.originAllowed(r.Header.Get("Origin")) {
		writeError(w, http.StatusForbidden, CodeOriginAllow,
			fmt.Sprintf("unexpected Origin %q", r.Header.Get("Origin")))
		return
	}

	// /v1/health is the single unauthenticated endpoint (§8.1): the
	// proof-of-token probe must work before the client trusts us with
	// anything, including its bearer token. The protocol header is
	// validated when present but not required here - a probing client
	// may be version-checking us.
	if r.URL.Path == "/v1/health" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, CodeNoRoute, "use GET /v1/health")
			return
		}
		if p := r.Header.Get("Station-Protocol"); p != "" && !acceptedProtocols[p] {
			s.rejectProtocol(w, p)
			return
		}
		s.handleHealth(w, r)
		return
	}

	// Everything else: protocol version, then bearer token, then route.
	p := r.Header.Get("Station-Protocol")
	if !acceptedProtocols[p] {
		s.rejectProtocol(w, p)
		return
	}
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="voxgig-station"`)
		writeError(w, http.StatusUnauthorized, CodeTokenAllow,
			"missing or invalid bearer token (see ~/.voxgig/station/token)")
		return
	}

	switch r.URL.Path {
	case "/v1/register":
		s.route(w, r, http.MethodPost, s.handleRegister)
	case "/v1/session":
		s.route(w, r, http.MethodDelete, s.handleSessionDelete)
	case "/v1/events":
		s.route(w, r, http.MethodPost, s.handleEvents)
	case "/v1/tap":
		s.route(w, r, http.MethodGet, s.handleTap)
	case "/v1/status":
		s.route(w, r, http.MethodGet, s.handleStatus)
	default:
		writeError(w, http.StatusNotFound, CodeNoRoute,
			fmt.Sprintf("unknown path %q", r.URL.Path))
	}
}

func (s *Server) route(w http.ResponseWriter, r *http.Request, method string, h func(http.ResponseWriter, *http.Request)) {
	if r.Method != method {
		writeError(w, http.StatusMethodNotAllowed, CodeNoRoute,
			fmt.Sprintf("use %s %s", method, r.URL.Path))
		return
	}
	h(w, r)
}

func (s *Server) rejectProtocol(w http.ResponseWriter, presented string) {
	if presented == "" {
		presented = "(absent)"
	}
	writeError(w, http.StatusBadRequest, CodeProtocol,
		fmt.Sprintf("unsupported Station-Protocol %s; this daemon speaks 1", presented))
}

// authorized checks the bearer token in constant time (§8.1:
// token-on-every-request).
func (s *Server) authorized(r *http.Request) bool {
	auth := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(auth) <= len(prefix) || !strings.EqualFold(auth[:len(prefix)], prefix) {
		return false
	}
	return tokenEqual(strings.TrimSpace(auth[len(prefix):]), s.token)
}

// --- handlers -----------------------------------------------------------

// handleHealth answers the probe. With ?nonce=N it also carries the
// §8.1 proof-of-token header, so a client can verify it is talking to
// the real daemon - the holder of the 0600 token file - before sending
// its bearer token, envelopes, or events. The body itself contains
// nothing sensitive.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if nonce := r.URL.Query().Get("nonce"); nonce != "" {
		w.Header().Set("Station-Proof", Proof(s.token, nonce))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"station":  "voxgig-station",
		"version":  Version,
		"protocol": Protocol,
	})
}

type registerRequest struct {
	Descriptor json.RawMessage `json:"descriptor"`
	Process    Process         `json:"process"`
	// Identity is reserved (§8.2): accepted on wire v1, ignored by a
	// local proxy (§8.4; D-2026-08-24-2 - no per-principal state in v1).
	Identity json.RawMessage `json:"identity"`
}

// handleRegister implements POST /v1/register (§8.2). The descriptor is
// untrusted input (§8.3): it is stored verbatim for status and
// observability, and nothing security-relevant is derived from it - no
// egress allowlist, no secret name, no policy. With no proxy-side
// policy authority in this phase, the registration parks in "pending"
// and the binding says so.
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.cfg.RegisterBodyLimit))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, CodeBodyLimit,
				fmt.Sprintf("register body over the %d byte limit", s.cfg.RegisterBodyLimit))
			return
		}
		writeError(w, http.StatusBadRequest, CodeRegisterInvalid, "unreadable request body")
		return
	}

	var req registerRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, CodeRegisterInvalid,
			"register body is not a JSON object: "+err.Error())
		return
	}
	if len(req.Descriptor) == 0 || string(req.Descriptor) == "null" {
		writeError(w, http.StatusBadRequest, CodeRegisterInvalid, "missing descriptor")
		return
	}

	// Hash of the bytes as received: an observability label for spotting
	// re-registrations (§3.4), not the §4 canonical-form hash.
	sum := sha256.Sum256(req.Descriptor)

	sess := s.sessions.Register(
		pluginLabel(req.Descriptor), req.Process, req.Descriptor,
		hex.EncodeToString(sum[:]), req.Identity)

	// The binding (§3.1) will carry resolved base/server variables, the
	// credential plan and effective policy once the proxy-side policy
	// authority (§8.3) and grants (§5.3) phases land; until then it
	// carries what this phase can honestly assert.
	writeJSON(w, http.StatusOK, map[string]any{
		"session": sess.ID,
		"binding": map[string]any{
			"state":      sess.State,
			"capture":    "meta", // §6 default capture depth
			"protocol":   Protocol,
			"ttlSeconds": int(s.sessions.TTL().Seconds()),
		},
	})
}

// pluginLabel extracts a display label from the untrusted descriptor -
// best-effort, observability only (§8.3). The descriptor's `name` is the
// api identity; `slug` the hyphenated machine form (§4).
func pluginLabel(descriptor json.RawMessage) string {
	var probe struct {
		Name string `json:"name"`
		Slug string `json:"slug"`
	}
	if err := json.Unmarshal(descriptor, &probe); err == nil {
		if probe.Slug != "" {
			return probe.Slug
		}
		if probe.Name != "" {
			return probe.Name
		}
	}
	return "unknown"
}

// handleSessionDelete implements DELETE /v1/session (§8.2): clean
// shutdown. Idempotent to match §3.4's close semantics - deleting an
// already-gone session succeeds and says so.
func (s *Server) handleSessionDelete(w http.ResponseWriter, r *http.Request) {
	id := r.Header.Get("Station-Session")
	if id == "" {
		writeError(w, http.StatusBadRequest, CodeNoSession, "missing Station-Session header")
		return
	}
	removed := s.sessions.Delete(id)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "removed": removed})
}

// handleEvents implements POST /v1/events (§8.2): an NDJSON batch into
// the bounded ring, fanned out to tap subscribers. The batch carries
// session liveness (§3.4 - no separate heartbeat endpoint). Ingest is
// deliberately lenient (§6: events never fail an operation): a malformed
// line is counted and skipped, an over-long line truncates the rest of
// the batch, and both are reported in the response and in status.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	id := r.Header.Get("Station-Session")
	if id == "" {
		writeError(w, http.StatusBadRequest, CodeNoSession, "missing Station-Session header")
		return
	}
	// Unknown or expired reads the same: the library re-registers (§3.4:
	// reattachment is always a full re-register).
	if !s.sessions.Touch(id) {
		writeError(w, http.StatusNotFound, CodeNoSession, "unknown or expired session; re-register")
		return
	}

	sc := bufio.NewScanner(http.MaxBytesReader(w, r.Body, s.cfg.EventsBodyLimit))
	sc.Buffer(make([]byte, 64*1024), s.cfg.EventLineLimit)

	var accepted, invalid uint64
	truncated := false
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		// A StationEvent is a JSON object (§6); anything else is noise.
		if line[0] != '{' || !json.Valid(line) {
			invalid++
			continue
		}
		// Copy out of the scanner-owned buffer; ring and hub share the
		// immutable copy.
		cp := append([]byte(nil), line...)
		s.ring.Push(cp)
		s.hub.Publish(cp, eventPlugin(cp))
		accepted++
	}
	if err := sc.Err(); err != nil {
		var mbe *http.MaxBytesError
		switch {
		case errors.As(err, &mbe):
			// Batch over the configured limit: what was scanned is kept,
			// and the structured error tells the library to split (§8.5's
			// structured-error convention for body limits).
			s.sessions.AddEvents(id, accepted)
			s.invalidEvents.Add(invalid)
			writeError(w, http.StatusRequestEntityTooLarge, CodeBodyLimit,
				fmt.Sprintf("events batch over the %d byte limit (%d events ingested)",
					s.cfg.EventsBodyLimit, accepted))
			return
		case errors.Is(err, bufio.ErrTooLong):
			truncated = true
		default:
			truncated = true
		}
	}

	s.sessions.AddEvents(id, accepted)
	s.invalidEvents.Add(invalid)

	resp := map[string]any{"accepted": accepted, "invalid": invalid}
	if truncated {
		resp["truncated"] = true
	}
	writeJSON(w, http.StatusOK, resp)
}

// eventPlugin pulls the instance name off an event line for tap
// filtering (§6: `plugin` carries the instance name).
func eventPlugin(line []byte) string {
	var probe struct {
		Plugin string `json:"plugin"`
	}
	_ = json.Unmarshal(line, &probe)
	return probe.Plugin
}

// handleTap implements GET /v1/tap: a live NDJSON stream of events as
// they arrive - chunked, quiet when idle, no backlog replay (the CLI
// `tap` skin; the cursor-based query surface over the ring is the later
// traffic endpoint). ?plugin=<instance> narrows to one instance.
func (s *Server) handleTap(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, CodeNoRoute, "streaming unsupported by transport")
		return
	}

	id, ch := s.hub.Subscribe(r.URL.Query().Get("plugin"))
	defer s.hub.Unsubscribe(id)

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	ctx := r.Context()
	var out []byte // per-subscriber buffer: the event line is shared, never mutated
	for {
		select {
		case <-ctx.Done():
			return
		case line := <-ch:
			out = append(out[:0], line...)
			out = append(out, '\n')
			if _, err := w.Write(out); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// handleStatus implements GET /v1/status: sessions and registered
// plugins with their state, ring fill, bounds, uptime (§8.5: bounds are
// visible in status; §3.4: liveness shown is truthful - expired sessions
// are purged before reporting).
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	now := s.cfg.Now()
	sessions := s.sessions.List()

	type sessionView struct {
		Session          string  `json:"session"`
		Plugin           string  `json:"plugin"`
		State            string  `json:"state"`
		Process          Process `json:"process"`
		RegisteredAt     string  `json:"registeredAt"`
		LastSeen         string  `json:"lastSeen"`
		ExpiresAt        string  `json:"expiresAt"`
		Events           uint64  `json:"events"`
		DescriptorSHA256 string  `json:"descriptorSha256"`
	}
	type pluginView struct {
		Plugin   string `json:"plugin"`
		State    string `json:"state"`
		Sessions int    `json:"sessions"`
	}

	sessViews := make([]sessionView, 0, len(sessions))
	byPlugin := map[string]*pluginView{}
	pluginOrder := []string{}
	for _, sess := range sessions {
		sessViews = append(sessViews, sessionView{
			Session:          sess.ID,
			Plugin:           sess.Plugin,
			State:            sess.State,
			Process:          sess.Proc,
			RegisteredAt:     sess.RegisteredAt.UTC().Format(time.RFC3339),
			LastSeen:         sess.LastSeen.UTC().Format(time.RFC3339),
			ExpiresAt:        sess.LastSeen.Add(s.sessions.TTL()).UTC().Format(time.RFC3339),
			Events:           sess.Events,
			DescriptorSHA256: sess.DescriptorSHA,
		})
		pv, ok := byPlugin[sess.Plugin]
		if !ok {
			pv = &pluginView{Plugin: sess.Plugin, State: sess.State}
			byPlugin[sess.Plugin] = pv
			pluginOrder = append(pluginOrder, sess.Plugin)
		}
		pv.Sessions++
	}
	pluginViews := make([]pluginView, 0, len(pluginOrder))
	for _, name := range pluginOrder {
		pluginViews = append(pluginViews, *byPlugin[name])
	}

	tapSubs, tapDropped := s.hub.Stats()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"version":       Version,
		"protocol":      Protocol,
		"listen":        s.cfg.Listen,
		"uptimeSeconds": int64(now.Sub(s.start) / time.Second),
		"sessions":      sessViews,
		"plugins":       pluginViews,
		"events": map[string]any{
			"ring":           s.ring.Stats(),
			"invalid":        s.invalidEvents.Load(),
			"tapSubscribers": tapSubs,
			"tapDropped":     tapDropped,
		},
		"bounds": map[string]any{
			"ringCapacity":      s.cfg.RingCapacity,
			"sessionTtlSeconds": int(s.cfg.SessionTTL.Seconds()),
			"registerBodyBytes": s.cfg.RegisterBodyLimit,
			"eventsBodyBytes":   s.cfg.EventsBodyLimit,
			"eventLineBytes":    s.cfg.EventLineLimit,
			"tapBufferEvents":   s.cfg.TapBuffer,
		},
	})
}
