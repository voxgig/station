package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sort"
	"sync"
	"time"
)

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
	ID     string
	Plugin string
	Proc   Process

	Descriptor json.RawMessage

	// DescriptorSHA is the hex SHA-256 of the descriptor bytes as
	// received - an observability label for spotting re-registrations,
	// not the §4 canonical-form hash (that dedupe arrives with the
	// canonical serializer).
	DescriptorSHA string

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

func (s *Sessions) AddEvents(id string, n uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.m[id]; ok {
		sess.Events += n
	}
}

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

func (s *Sessions) TTL() time.Duration { return s.ttl }
