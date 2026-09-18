package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// forwardEnvelope is §8.2's request envelope. Header values may be a
// string or a list of strings. The body is buffered in v1 with the
// §8.5 32 MB limit; streaming uploads are an open question (§18).
type forwardEnvelope struct {
	URL     string         `json:"url"`
	Method  string         `json:"method"`
	Headers map[string]any `json:"headers"`
	Body    string         `json:"body"`
}

// placeholderRe matches the inert credential placeholder the library
// plants (the `placeholder` corpus section pins the exact form,
// `[station:<instance>]`). Injection replaces the placeholder in place,
// which is what preserves an auth scheme prefix: the envelope's
// "Bearer [station:x]" becomes "Bearer <value>".
var placeholderRe = regexp.MustCompile(`\[station:[^\]]*\]`)

func newUpstreamClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

type cappedBuffer struct {
	max   int
	buf   bytes.Buffer
	total int64
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	c.total += int64(len(p))
	if room := c.max - c.buf.Len(); room > 0 {
		if len(p) > room {
			c.buf.Write(p[:room])
		} else {
			c.buf.Write(p)
		}
	}
	return len(p), nil
}

func (c *cappedBuffer) truncated() bool { return c.total > int64(c.buf.Len()) }

func parseRedactNames(header string) map[string]bool {
	names := map[string]bool{}
	for _, part := range strings.Split(header, ",") {
		if name := strings.ToLower(strings.TrimSpace(part)); name != "" {
			names[name] = true
		}
	}
	return names
}

func envelopeHeaders(raw map[string]any) (http.Header, error) {
	h := http.Header{}
	for k, v := range raw {
		switch value := v.(type) {
		case string:
			h.Add(k, value)
		case []any:
			for _, item := range value {
				s, ok := item.(string)
				if !ok {
					return nil, fmt.Errorf("header %q: values must be strings", k)
				}
				h.Add(k, s)
			}
		default:
			return nil, fmt.Errorf("header %q: value must be a string or list of strings", k)
		}
	}
	return h, nil
}

// envelopeHost returns the envelope's Host override, if any. Go's
// http.Header canonicalizes the name, so a client's `host:` and `Host:`
// are one key here; the FIRST value is the one the request would carry.
func envelopeHost(h http.Header) string {
	for k, vs := range h {
		if strings.EqualFold(k, "Host") && len(vs) > 0 {
			return vs[0]
		}
	}
	return ""
}

// injectCredential swaps the resolved value in for the placeholder,
// wherever the placeholder appears (§5.3 R2: the proxy swaps in the
// real credential on the outbound hop). When no placeholder is present
// and no Authorization header exists, the value is set as the
// Authorization header verbatim.
func injectCredential(h http.Header, value string) {
	replaced := false
	for k, vs := range h {
		for i, v := range vs {
			if placeholderRe.MatchString(v) {
				vs[i] = placeholderRe.ReplaceAllString(v, value)
				replaced = true
			}
		}
		h[k] = vs
	}
	if !replaced && h.Get("Authorization") == "" {
		h.Set("Authorization", value)
	}
}

func (s *Server) handleForward(w http.ResponseWriter, r *http.Request) {
	id := r.Header.Get("Station-Session")
	if id == "" {
		writeError(w, http.StatusBadRequest, CodeNoSession, "missing Station-Session header")
		return
	}
	if !s.sessions.Touch(id) {
		writeError(w, http.StatusNotFound, CodeNoSession, "unknown or expired session; re-register")
		return
	}
	sess, _ := s.sessions.Get(id)
	ref := sess.Plugin
	if sp := r.Header.Get("Station-Plugin"); sp != "" && sp != ref {
		writeError(w, http.StatusBadRequest, CodeForwardInvalid,
			fmt.Sprintf("Station-Plugin %q does not match the session's instance %q", sp, ref))
		return
	}
	corr := r.Header.Get("Station-Corr")
	redactNames := parseRedactNames(r.Header.Get("Station-Redact"))

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.cfg.ForwardBodyLimit))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, CodeBodyLimit,
				fmt.Sprintf("forward body over the %d byte limit", s.cfg.ForwardBodyLimit))
			return
		}
		writeError(w, http.StatusBadRequest, CodeForwardInvalid, "unreadable request body")
		return
	}

	var env forwardEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		writeError(w, http.StatusBadRequest, CodeForwardInvalid,
			"envelope is not a JSON object: "+err.Error())
		return
	}
	target, err := url.Parse(env.URL)
	if err != nil || !target.IsAbs() || (target.Scheme != "http" && target.Scheme != "https") || target.Hostname() == "" {
		writeError(w, http.StatusBadRequest, CodeForwardInvalid,
			fmt.Sprintf("envelope url must be an absolute http(s) URL, got %q", env.URL))
		return
	}
	method := strings.ToUpper(env.Method)
	if method == "" {
		method = http.MethodGet
	}
	upHeaders, err := envelopeHeaders(env.Headers)
	if err != nil {
		writeError(w, http.StatusBadRequest, CodeForwardInvalid, err.Error())
		return
	}

	eff := s.policy.EffectiveFor(ref)
	// §16's kill switch, enforced at the proxy data-plane seam. It is
	// checked BEFORE the allowlist and before any credential is
	// resolved, and it does not care whether the instance is approved:
	// `block` in the proxy-side profile means this instance sends
	// nothing, whatever the client believes or whether it checks at all.
	if eff.Mode == ModeBlock {
		writeError(w, http.StatusForbidden, CodeHostAllow, blockedMessage(ref))
		return
	}
	if eff.State == StateApproved {
		hosts := narrowHosts(eff.Hosts, descriptorBase(sess.Descriptor))
		if !hostAllowed(hosts, target.Hostname(), target.Port()) {
			writeError(w, http.StatusForbidden, CodeHostAllow,
				fmt.Sprintf("egress to %q denied by the hosts policy for %q (allowed: %s)",
					target.Hostname(), ref, strings.Join(hosts, ", ")))
			return
		}
	}

	if host := envelopeHost(upHeaders); host != "" &&
		!strings.EqualFold(host, target.Host) && !strings.EqualFold(host, target.Hostname()) {
		writeError(w, http.StatusForbidden, CodeHostAllow,
			fmt.Sprintf("envelope Host %q does not match the target authority %q for %q: "+
				"only the URL's authority is policed, so an override cannot re-aim the request",
				host, target.Host, ref))
		return
	}

	var transient []string
	for name := range redactNames {
		for _, v := range upHeaders.Values(name) {
			if v == "" {
				continue
			}
			transient = append(transient, v)
			if i := strings.LastIndexByte(v, ' '); i >= 0 && i+1 < len(v) {
				transient = append(transient, v[i+1:])
			}
		}
	}

	// R2 injection (§5.3): a valid per-instance grant lets the proxy
	// resolve the credential through ITS OWN sekreto by ITS OWN mapping
	// - eff.Secret comes from proxy-side config/derivation (§8.3),
	// never from anything the client sent.
	injected := false
	if token := r.Header.Get("Station-Grant"); token != "" {
		grant, reason := s.grants.Validate(token, ref, id)
		if grant == nil {
			writeError(w, http.StatusForbidden, CodeGrantExpired, reason)
			return
		}
		value, rerr := s.broker.value(ref, grant.Secret)
		if rerr != nil {
			writeError(w, http.StatusBadGateway, rerr.code, rerr.message)
			return
		}
		injectCredential(upHeaders, value)
		injected = true
	}

	ureq, err := http.NewRequestWithContext(r.Context(), method, env.URL,
		bytes.NewReader([]byte(env.Body)))
	if err != nil {
		writeError(w, http.StatusBadRequest, CodeForwardInvalid, err.Error())
		return
	}
	for k, vs := range upHeaders {
		if strings.EqualFold(k, "Host") {
			if len(vs) > 0 {
				ureq.Host = vs[0]
			}
			continue
		}
		ureq.Header[http.CanonicalHeaderKey(k)] = vs
	}

	start := time.Now()
	ures, err := s.upstream.Do(ureq)
	if err != nil {
		s.recordCapture(&exchange{
			sess: sess, corr: corr, eff: eff, redactNames: redactNames,
			transient: transient, injected: injected, env: &env,
			envHeaders: env.Headers, status: 0,
			duration: time.Since(start), upstreamErr: err.Error(),
		})
		writeError(w, http.StatusBadGateway, CodeUpstream,
			s.broker.scrub("upstream request failed: "+err.Error()))
		return
	}
	defer ures.Body.Close()

	out := w.Header()
	out.Set("Station-Status", strconv.Itoa(ures.StatusCode))
	for k, vs := range ures.Header {
		for _, v := range vs {
			out.Add("Station-Up-"+k, v)
		}
	}
	out.Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)

	capBody := &cappedBuffer{max: s.cfg.CaptureBodyLimit}
	_, _ = io.Copy(w, io.TeeReader(ures.Body, capBody))

	s.recordCapture(&exchange{
		sess: sess, corr: corr, eff: eff, redactNames: redactNames,
		transient: transient, injected: injected, env: &env,
		envHeaders: env.Headers, status: ures.StatusCode,
		resHeaders: ures.Header, resBody: capBody,
		duration: time.Since(start),
	})
}

func descriptorBase(descriptor json.RawMessage) string {
	var probe struct {
		Base string `json:"base"`
	}
	_ = json.Unmarshal(descriptor, &probe)
	return probe.Base
}

type exchange struct {
	sess        Session
	corr        string
	eff         Effective
	redactNames map[string]bool
	transient   []string
	injected    bool
	env         *forwardEnvelope
	envHeaders  map[string]any
	status      int
	resHeaders  http.Header
	resBody     *cappedBuffer
	duration    time.Duration
	upstreamErr string
}

func hasUnscrubbableCredential(headers http.Header, redactNames map[string]bool, injected bool) bool {
	for k, vs := range headers {
		lk := strings.ToLower(k)
		if !redactHeaderList[lk] || redactNames[lk] {
			continue
		}
		for _, v := range vs {
			if v == "" || placeholderRe.MatchString(v) {
				continue
			}
			if injected && lk == "authorization" {
				continue
			}
			return true
		}
	}
	return false
}

// bodyCredentialRe finds credential-shaped assignments in a request
// body - `client_secret=...` in a form post, `"refresh_token": "..."`
// in JSON - covering the token-exchange shape §15's header rule cannot
// see. It is the body analogue of redactHeaderList: a shape test, not a
// value test, because the proxy has no other way to know.
var bodyCredentialRe = regexp.MustCompile(
	`(?i)"?\b(client[_-]?secret|client[_-]?assertion|refresh[_-]?token|` +
		`access[_-]?token|id[_-]?token|session[_-]?token|private[_-]?key|` +
		`api[_-]?key|apikey|password|passwd|passcode|credential|assertion|` +
		`secret|token|bearer)"?\s*[:=]\s*"?([^"'&,\s}\]]+)"?`)

func hasUnscrubbableBodyCredential(body string, values []string) bool {
	if body == "" {
		return false
	}
	for _, m := range bodyCredentialRe.FindAllStringSubmatch(body, -1) {
		value := m[2]
		if value == "" || placeholderRe.MatchString(value) {
			continue
		}
		covered := false
		for _, v := range values {
			if v != "" && strings.Contains(value, v) {
				covered = true
				break
			}
		}
		if !covered {
			return true
		}
	}
	return false
}

func (s *Server) recordCapture(x *exchange) {
	depth := x.eff.Capture
	if depth != "meta" && depth != "headers" && depth != "full" {
		depth = "meta"
	}

	envHdr, _ := envelopeHeaders(x.envHeaders)

	// Scrub set: this exchange's transient Station-Redact values plus
	// every value the proxy's broker ever resolved (§5.3, §7 - exact
	// match, no length floor). Computed before the degrade check
	// because that check asks exactly what this set can cover.
	values := append(append([]string(nil), x.transient...), s.broker.heldValues()...)

	storedReqBody := x.env.Body
	if len(storedReqBody) > s.cfg.CaptureBodyLimit {
		storedReqBody = storedReqBody[:s.cfg.CaptureBodyLimit]
	}

	degraded := false
	if depth == "full" &&
		(hasUnscrubbableCredential(envHdr, x.redactNames, x.injected) ||
			hasUnscrubbableBodyCredential(storedReqBody, values)) {
		// §15: the library sent no Station-Redact marker for a real
		// credential, in a header or in the body - degrade this plugin's
		// capture to headers rather than store bytes the proxy cannot
		// scrub, and say so in status.
		depth = "headers"
		degraded = true
	}

	entry := &CaptureEntry{
		T:        s.cfg.Now().UTC().Format(time.RFC3339),
		Session:  x.sess.ID,
		Plugin:   x.sess.Plugin,
		Corr:     x.corr,
		Depth:    depth,
		Degraded: degraded,
	}
	entry.ReqMethod = strings.ToUpper(x.env.Method)
	if entry.ReqMethod == "" {
		entry.ReqMethod = http.MethodGet
	}
	entry.ReqURL, _ = scrubText(x.env.URL, values)
	entry.ReqBodyBytes = int64(len(x.env.Body))
	entry.Status = x.status
	entry.DurationMs = x.duration.Milliseconds()
	if x.resBody != nil {
		entry.ResBodyBytes = x.resBody.total
	}

	replayable := true
	reason := ""
	if depth == "headers" || depth == "full" {
		entry.ReqHeaders = scrubHeaders(envHdr, x.redactNames, values)
		if x.resHeaders != nil {
			entry.ResHeaders = scrubHeaders(x.resHeaders, nil, values)
		}
	}
	if depth == "full" {
		entry.ReqTruncated = len(storedReqBody) < len(x.env.Body)
		scrubbed, changed := scrubText(storedReqBody, values)
		entry.ReqBody = scrubbed

		// §8.5: replayable is false when the request body was truncated
		// or redaction replaced bytes the request needs. Redacted AUTH
		// HEADERS are the exception - replay restores those through the
		// credential path (§6) - so header redaction above never clears
		// the flag; only request-BODY damage does.
		if entry.ReqTruncated {
			replayable, reason = false, "request body truncated at capture"
		} else if changed {
			replayable, reason = false, "redaction replaced request-body bytes"
		}

		if x.resBody != nil {
			resBody, _ := scrubText(x.resBody.buf.String(), values)
			entry.ResBody = resBody
			entry.ResTruncated = x.resBody.truncated()
		}
	} else if len(x.env.Body) > 0 {
		// A body the store never held cannot be re-issued byte-for-byte.
		replayable, reason = false, "request body not captured at depth "+depth
	}
	if x.upstreamErr != "" {
		msg, _ := scrubText("upstream error: "+x.upstreamErr, values)
		entry.Reason = msg
		replayable = false
		if reason == "" {
			reason = "upstream never answered"
		}
	}
	entry.Replayable = replayable
	if !replayable && entry.Reason == "" {
		entry.Reason = reason
	}

	s.captures.Add(entry)
}
