package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sort"
	"sync"
	"time"
)

// Registration state lives with the policy authority (policy.go): a
// session's pending/approved state is COMPUTED from the proxy-side
// policy store at each use, never stored here - approval and
// triple-change-re-enters-pending (§8.3) must apply to live sessions
// immediately.

// Process is the self-reported process identity from /v1/register
// (§8.2). Observability only - like the descriptor it is untrusted
// input and nothing security-relevant may be derived from it (§8.3).
type Process struct {
	Pid  int    `json:"pid,omitempty"`
	Lang string `json:"lang,omitempty"`
	App  string `json:"app,omitempty"`
}

// Session is one registration (§3.4: one register call, one session; a
// re-registration is a new session).
type Session struct {
	ID string
	// Plugin is the instance ref this registration bound (`name$tag`;
	// an untagged ref is the api slug, §3.2). Client-claimed - policy
	// keyed by it stays safe because which secret a ref resolves and
	// which hosts it may reach come from PROXY-side config (§8.3), and
	// local v1 is single-team by policy (D-2026-08-24-2).
	Plugin string
	Proc   Process

	// Descriptor is stored verbatim (§8.3: untrusted input, kept for
	// status/observability; the proxy derives no policy, no secret name
	// and no egress allowlist from it).
	Descriptor json.RawMessage

	// DescriptorSHA is the hex SHA-256 of the descriptor bytes as
	// received - an observability label for spotting re-registrations,
	// not the §4 canonical-form hash (that dedupe arrives with the
	// canonical serializer).
	DescriptorSHA string

	// Identity is §8.2's reserved field: accepted so wire v1 does not
	// need a v2 for remote mode, ignored by a local proxy (§8.4,
	// decision D-2026-08-24-2: no per-principal state anywhere in v1).
	Identity json.RawMessage

	RegisteredAt time.Time
	LastSeen     time.Time
	Events       uint64
}

// Sessions is the in-memory session store. Sessions expire on TTL;
// liveness piggybacks on /v1/events batches - there is no separate
// heartbeat endpoint (§3.4). Expired sessions are purged lazily on
// lookup and on List, so status shows truthful liveness, not ghosts.
type Sessions struct {
	mu  sync.Mutex
	m   map[string]*Session
	ttl time.Duration
	now func() time.Time
}

func NewSessions(ttl time.Duration, now func() time.Time) *Sessions {
	return &Sessions{m: map[string]*Session{}, ttl: ttl, now: now}
}

func newID() string {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		// crypto/rand failing means the platform is broken; an ID the
		// process cannot generate is not a recoverable condition.
		panic("station: cannot generate session id: " + err.Error())
	}
	return hex.EncodeToString(raw)
}

// Register creates a session for a registration.
func (s *Sessions) Register(plugin string, proc Process, descriptor json.RawMessage, descriptorSHA string, identity json.RawMessage) *Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	sess := &Session{
		ID:            newID(),
		Plugin:        plugin,
		Proc:          proc,
		Descriptor:    descriptor,
		DescriptorSHA: descriptorSHA,
		Identity:      identity,
		RegisteredAt:  now,
		LastSeen:      now,
	}
	s.m[sess.ID] = sess
	return sess
}

func (s *Sessions) expiredLocked(sess *Session, now time.Time) bool {
	return now.Sub(sess.LastSeen) > s.ttl
}

// Touch looks up a session, purging it if expired, and refreshes its
// liveness. Returns false for unknown or expired sessions - the signal
// for the library to fully re-register (§3.4).
func (s *Sessions) Touch(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.m[id]
	if !ok {
		return false
	}
	now := s.now()
	if s.expiredLocked(sess, now) {
		delete(s.m, id)
		return false
	}
	sess.LastSeen = now
	return true
}

// Get returns a copy of a live session without touching liveness.
func (s *Sessions) Get(id string) (Session, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.m[id]
	if !ok || s.expiredLocked(sess, s.now()) {
		return Session{}, false
	}
	return *sess, true
}

// LatestDescriptorBase returns the base URL claimed by the most recent
// live registration of ref - the proxy-side view of the descriptor,
// used only for the approve-time hosts default (§16) and narrowing
// (§8.3), where untrusted input may act because it can only narrow.
func (s *Sessions) LatestDescriptorBase(ref string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	base := ""
	var latest time.Time
	for _, sess := range s.m {
		if sess.Plugin != ref || s.expiredLocked(sess, now) {
			continue
		}
		if sess.RegisteredAt.After(latest) || base == "" {
			if b := descriptorBase(sess.Descriptor); b != "" {
				base = b
				latest = sess.RegisteredAt
			}
		}
	}
	return base
}

// LatestDescriptor returns the verbatim descriptor of the most recent
// live registration of ref - the §7 tools' source for entity/op shape.
// Untrusted input: the agent surface derives candidate lists and
// request synthesis from it, while hosts policy and secret selection
// stay proxy-side (§8.3), so a hostile descriptor cannot widen egress
// or pick a secret.
func (s *Sessions) LatestDescriptor(ref string) json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	var descriptor json.RawMessage
	var latest time.Time
	for _, sess := range s.m {
		if sess.Plugin != ref || s.expiredLocked(sess, now) {
			continue
		}
		if descriptor == nil || sess.RegisteredAt.After(latest) {
			descriptor = sess.Descriptor
			latest = sess.RegisteredAt
		}
	}
	return descriptor
}

// Refs lists the distinct instance refs with live sessions, sorted.
func (s *Sessions) Refs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	seen := map[string]bool{}
	for _, sess := range s.m {
		if !s.expiredLocked(sess, now) {
			seen[sess.Plugin] = true
		}
	}
	out := make([]string, 0, len(seen))
	for ref := range seen {
		out = append(out, ref)
	}
	sort.Strings(out)
	return out
}

// AddEvents credits n ingested events to the session, if it still exists.
func (s *Sessions) AddEvents(id string, n uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.m[id]; ok {
		sess.Events += n
	}
}

// Delete removes a session, reporting whether it existed (and was live).
func (s *Sessions) Delete(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.m[id]
	if !ok {
		return false
	}
	expired := s.expiredLocked(sess, s.now())
	delete(s.m, id)
	return !expired
}

// List purges expired sessions and returns copies of the live ones,
// oldest registration first.
func (s *Sessions) List() []Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	out := make([]Session, 0, len(s.m))
	for id, sess := range s.m {
		if s.expiredLocked(sess, now) {
			delete(s.m, id)
			continue
		}
		out = append(out, *sess)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].RegisteredAt.Equal(out[j].RegisteredAt) {
			return out[i].ID < out[j].ID
		}
		return out[i].RegisteredAt.Before(out[j].RegisteredAt)
	})
	return out
}

// TTL exposes the configured liveness window (surfaced in bindings and
// status).
func (s *Sessions) TTL() time.Duration { return s.ttl }
