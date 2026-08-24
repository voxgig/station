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
	"strconv"
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
	policy   *PolicyStore
	grants   *Grants
	broker   *broker
	captures *CaptureStore
	upstream *http.Client

	// allowedHosts is the §8.1 DNS-rebinding allowlist, derived from the
	// bound address: exact Host header values (and Origin authorities)
	// this daemon answers to.
	allowedHosts map[string]bool

	invalidEvents atomic.Uint64
}

// NewServer builds the daemon handler. cfg.Listen must be the actual
// bound address (it seeds the Host/Origin allowlist). It loads the
// proxy-side station.json (cfg.StationConfigPath), the approval state
// (cfg.StatePath), and builds the proxy's own sekreto chain from the
// selected profile's providers (§8.3) - failures here are startup
// failures, not per-request surprises.
func NewServer(cfg Config, token string) (*Server, error) {
	cfg = cfg.withDefaults()

	stationCfg, err := loadStationConfig(cfg.StationConfigPath, cfg.Profile)
	if err != nil {
		return nil, err
	}
	policy, err := NewPolicyStore(stationCfg, cfg.StatePath, cfg.Now)
	if err != nil {
		return nil, err
	}
	var providers []any
	if stationCfg != nil {
		providers = stationCfg.Providers
	}
	brk, err := newBroker(providers)
	if err != nil {
		return nil, err
	}

	s := &Server{
		cfg:          cfg,
		token:        token,
		start:        cfg.Now(),
		ring:         NewRing(cfg.RingCapacity),
		hub:          NewHub(cfg.TapBuffer),
		sessions:     NewSessions(cfg.SessionTTL, cfg.Now),
		policy:       policy,
		grants:       NewGrants(cfg.GrantTTL, cfg.Now),
		broker:       brk,
		captures:     NewCaptureStore(cfg.CaptureMaxEntries, cfg.CaptureMaxBytes),
		upstream:     newUpstreamClient(cfg.UpstreamTimeout),
		allowedHosts: allowedHostSet(cfg.Listen),
	}
	return s, nil
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

	// The MCP endpoint (§7) negotiates its own protocol version inside
	// `initialize` and its clients (MCP hosts) cannot send custom
	// station headers, so it skips the Station-Protocol check - but
	// keeps bearer auth and sits behind the same §8.1 Host/Origin
	// hardening applied above.
	if r.URL.Path == "/v1/mcp" {
		if !s.authorized(r) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="voxgig-station"`)
			writeError(w, http.StatusUnauthorized, CodeTokenAllow,
				"missing or invalid bearer token (see ~/.voxgig/station/token)")
			return
		}
		s.route(w, r, http.MethodPost, s.handleMCP)
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

	switch {
	case r.URL.Path == "/v1/register":
		s.route(w, r, http.MethodPost, s.handleRegister)
	case r.URL.Path == "/v1/session":
		s.route(w, r, http.MethodDelete, s.handleSessionDelete)
	case r.URL.Path == "/v1/events":
		s.route(w, r, http.MethodPost, s.handleEvents)
	case r.URL.Path == "/v1/forward":
		s.route(w, r, http.MethodPost, s.handleForward)
	case r.URL.Path == "/v1/tap":
		s.route(w, r, http.MethodGet, s.handleTap)
	case r.URL.Path == "/v1/traffic":
		s.route(w, r, http.MethodGet, s.handleTraffic)
	case r.URL.Path == "/v1/status":
		s.route(w, r, http.MethodGet, s.handleStatus)
	case strings.HasPrefix(r.URL.Path, "/v1/approve/"):
		s.routeRef(w, r, http.MethodPost, "/v1/approve/", s.handleApprove)
	case strings.HasPrefix(r.URL.Path, "/v1/grants/"):
		s.routeRef(w, r, http.MethodDelete, "/v1/grants/", s.handleGrantRevoke)
	case strings.HasPrefix(r.URL.Path, "/v1/policy/"):
		s.routeRef(w, r, http.MethodGet, "/v1/policy/", s.handlePolicy)
	default:
		writeError(w, http.StatusNotFound, CodeNoRoute,
			fmt.Sprintf("unknown path %q", r.URL.Path))
	}
}

// routeRef dispatches a /v1/<verb>/{ref} path, handing the handler the
// instance ref (D-2026-08-24-1: grants and policy address instances).
func (s *Server) routeRef(w http.ResponseWriter, r *http.Request, method string, prefix string, h func(http.ResponseWriter, *http.Request, string)) {
	if r.Method != method {
		writeError(w, http.StatusMethodNotAllowed, CodeNoRoute,
			fmt.Sprintf("use %s %s{ref}", method, prefix))
		return
	}
	ref := strings.TrimPrefix(r.URL.Path, prefix)
	if ref == "" || strings.Contains(ref, "/") {
		writeError(w, http.StatusNotFound, CodeNoRoute,
			fmt.Sprintf("unknown path %q", r.URL.Path))
		return
	}
	h(w, r, ref)
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
	// Instance is the ref this registration binds (`name$tag`); an
	// untagged ref is the api slug and the default is the descriptor's
	// slug, so single-instance clients need not send it (§3.2).
	Instance string `json:"instance"`
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

	ref := req.Instance
	if ref == "" {
		ref = pluginLabel(req.Descriptor)
	}

	sess := s.sessions.Register(
		ref, req.Process, req.Descriptor,
		hex.EncodeToString(sum[:]), req.Identity)

	// The binding (§3.1) reports the proxy-side effective policy for
	// this instance (§8.3: derived from the proxy's OWN config and
	// approvals, never from the registration). A pending instance gets
	// exactly what §8.3 grants it: capture and library-resolved traffic.
	eff := s.policy.EffectiveFor(ref)
	binding := map[string]any{
		"state":      eff.State,
		"capture":    eff.Capture,
		"resolve":    eff.Resolve,
		"protocol":   Protocol,
		"ttlSeconds": int(s.sessions.TTL().Seconds()),
	}
	if eff.State == StateApproved {
		binding["hosts"] = narrowHosts(eff.Hosts, descriptorBase(req.Descriptor))
		binding["secret"] = eff.Secret // the NAME (§4 Binding.secretname), never a value
		if eff.Resolve == "proxy" {
			// R2 (§5.3, D-2026-08-24-1): a per-INSTANCE grant, bound to
			// this session, TTL'd, renewed by re-registration (§3.4).
			grant := s.grants.Issue(ref, sess.ID, eff.Secret)
			binding["grant"] = grant.Token
			binding["grantTtlSeconds"] = int(s.grants.TTL().Seconds())
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"session": sess.ID,
		"binding": binding,
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

// handleApprove implements POST /v1/approve/{ref} - the HTTP surface
// under the `voxgig-station approve` CLI verb (§8.3): an explicit human
// decision blesses the base/hosts/name triple, upgrading the instance
// from pending. The hosts default may come from the proxy-side view of
// a live registration's descriptor base (§16) when config declares
// neither hosts nor base.
func (s *Server) handleApprove(w http.ResponseWriter, r *http.Request, ref string) {
	approval, err := s.policy.Approve(ref, s.sessions.LatestDescriptorBase(ref))
	if err != nil {
		writeError(w, http.StatusBadRequest, CodeConfigInvalid, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "approval": approval})
}

// handleGrantRevoke implements DELETE /v1/grants/{ref} (§5.3,
// D-2026-08-24-1): revocation is per instance and never touches
// siblings on the same api. It counts as a policy update, so
// long-pollers wake.
func (s *Server) handleGrantRevoke(w http.ResponseWriter, r *http.Request, ref string) {
	revoked := s.grants.RevokeRef(ref)
	s.policy.Bump(ref)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "revoked": revoked})
}

// policyView is the wire shape of GET /v1/policy/{ref}. Names only,
// never values (§7: secrets are structurally invisible on every
// observability surface).
func policyView(eff Effective) map[string]any {
	view := map[string]any{
		"ref":     eff.Ref,
		"version": eff.Version,
		"state":   eff.State,
		"covered": eff.Covered,
		"resolve": eff.Resolve,
		"capture": eff.Capture,
	}
	if eff.State == StateApproved {
		view["hosts"] = eff.Hosts
		view["secret"] = eff.Secret
		if eff.Base != "" {
			view["base"] = eff.Base
		}
		if eff.Approved != nil {
			view["approvedAt"] = eff.Approved.ApprovedAt
		}
	}
	return view
}

// handlePolicy implements GET /v1/policy/{ref} (§8.2): the current
// policy view, as a long-poll - a caller that passes ?version=<seen>
// is held until the version changes or the poll timeout (default 25s)
// passes, then answered with the current view either way.
func (s *Server) handlePolicy(w http.ResponseWriter, r *http.Request, ref string) {
	eff := s.policy.EffectiveFor(ref)
	if vq := r.URL.Query().Get("version"); vq != "" {
		since, err := strconv.Atoi(vq)
		if err != nil {
			writeError(w, http.StatusBadRequest, CodeForwardInvalid,
				"version must be an integer")
			return
		}
		var ch <-chan struct{}
		eff, ch = s.policy.WaitChan(ref, since)
		if ch != nil {
			timer := time.NewTimer(s.cfg.PolicyPollTimeout)
			defer timer.Stop()
			select {
			case <-ch:
			case <-timer.C:
			case <-r.Context().Done():
				return
			}
			eff = s.policy.EffectiveFor(ref)
		}
	}
	writeJSON(w, http.StatusOK, policyView(eff))
}

// handleTraffic implements GET /v1/traffic: the cursor-based query over
// the capture store (the wire home of `voxgig-station traffic` and the
// station_traffic tool). Entries were scrubbed at capture time (§15).
func (s *Server) handleTraffic(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	cursor, _ := strconv.ParseUint(q.Get("cursor"), 10, 64)
	limit := 50
	if raw := q.Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			writeError(w, http.StatusBadRequest, CodeNoRoute, "limit must be a positive integer")
			return
		}
		limit = n
	}
	if limit > 500 {
		limit = 500
	}
	entries, more := s.captures.Query(cursor, limit, q.Get("plugin"), q.Get("corr"))
	if entries == nil {
		entries = []*CaptureEntry{}
	}
	resp := map[string]any{"captures": entries, "more": more}
	if len(entries) > 0 {
		resp["next"] = entries[len(entries)-1].ID
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleStatus implements GET /v1/status: sessions and registered
// plugins with their state, ring fill, bounds, uptime (§8.5: bounds are
// visible in status; §3.4: liveness shown is truthful - expired sessions
// are purged before reporting).
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.statusPayload())
}

// statusPayload builds the status view - one payload behind both the
// HTTP endpoint and the station_status tool (§6: two skins, one API).
func (s *Server) statusPayload() map[string]any {
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
		Plugin  string `json:"plugin"`
		State   string `json:"state"`
		Resolve string `json:"resolve"`
		// Rung is the §5.3 isolation rung this registration runs at:
		// R2 when approved with resolve:proxy (the value never enters
		// the application process), else R1 (library-resolved hygiene).
		Rung     string `json:"rung"`
		Sessions int    `json:"sessions"`
	}

	sessViews := make([]sessionView, 0, len(sessions))
	byPlugin := map[string]*pluginView{}
	pluginOrder := []string{}
	for _, sess := range sessions {
		// State is computed from the policy authority at report time
		// (§8.3): approval - and a triple change re-entering pending -
		// applies to live sessions immediately.
		eff := s.policy.EffectiveFor(sess.Plugin)
		state := eff.State
		sessViews = append(sessViews, sessionView{
			Session:          sess.ID,
			Plugin:           sess.Plugin,
			State:            state,
			Process:          sess.Proc,
			RegisteredAt:     sess.RegisteredAt.UTC().Format(time.RFC3339),
			LastSeen:         sess.LastSeen.UTC().Format(time.RFC3339),
			ExpiresAt:        sess.LastSeen.Add(s.sessions.TTL()).UTC().Format(time.RFC3339),
			Events:           sess.Events,
			DescriptorSHA256: sess.DescriptorSHA,
		})
		pv, ok := byPlugin[sess.Plugin]
		if !ok {
			rung := "R1"
			if state == StateApproved && eff.Resolve == "proxy" {
				rung = "R2"
			}
			pv = &pluginView{Plugin: sess.Plugin, State: state, Resolve: eff.Resolve, Rung: rung}
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
	configFile, profile, covered, approved := s.policy.Snapshot()
	return map[string]any{
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
		"captures": s.captures.Stats(),
		"grants":   map[string]any{"active": s.grants.Active()},
		// The §7 agent gates, visible as promised: read defaults on
		// locally; write needs the explicit --agent-write flag AND
		// per-instance policy (station_policy shows that half).
		"agent": map[string]any{
			"read":  !s.cfg.AgentReadDisabled,
			"write": s.cfg.AgentWrite,
		},
		"policy": map[string]any{
			"configFile": configFile,
			"profile":    profile,
			"covered":    covered,
			"approved":   approved,
		},
		"bounds": map[string]any{
			"ringCapacity":       s.cfg.RingCapacity,
			"sessionTtlSeconds":  int(s.cfg.SessionTTL.Seconds()),
			"registerBodyBytes":  s.cfg.RegisterBodyLimit,
			"eventsBodyBytes":    s.cfg.EventsBodyLimit,
			"eventLineBytes":     s.cfg.EventLineLimit,
			"tapBufferEvents":    s.cfg.TapBuffer,
			"forwardBodyBytes":   s.cfg.ForwardBodyLimit,
			"captureMaxEntries":  s.cfg.CaptureMaxEntries,
			"captureMaxBytes":    s.cfg.CaptureMaxBytes,
			"captureBodyBytes":   s.cfg.CaptureBodyLimit,
			"grantTtlSeconds":    int(s.cfg.GrantTTL.Seconds()),
			"policyPollSeconds":  int(s.cfg.PolicyPollTimeout.Seconds()),
			"upstreamTimeoutSec": int(s.cfg.UpstreamTimeout.Seconds()),
		},
	}
}
