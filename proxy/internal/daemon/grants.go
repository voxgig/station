package daemon

import (
	"sync"
	"time"
)

type Grant struct {
	Token     string
	Ref       string
	Session   string
	Secret    string // sekreto NAME, never a value
	ExpiresAt time.Time
}

type Grants struct {
	mu      sync.Mutex
	byToken map[string]*Grant
	ttl     time.Duration
	now     func() time.Time
}

func NewGrants(ttl time.Duration, now func() time.Time) *Grants {
	return &Grants{byToken: map[string]*Grant{}, ttl: ttl, now: now}
}

func (g *Grants) Issue(ref string, session string, secret string) *Grant {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.purgeLocked()
	grant := &Grant{
		Token:     newID(),
		Ref:       ref,
		Session:   session,
		Secret:    secret,
		ExpiresAt: g.now().Add(g.ttl),
	}
	g.byToken[grant.Token] = grant
	return grant
}

func (g *Grants) purgeLocked() {
	now := g.now()
	for token, grant := range g.byToken {
		if now.After(grant.ExpiresAt) {
			delete(g.byToken, token)
		}
	}
}

func (g *Grants) Validate(token string, ref string, session string) (*Grant, string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	grant, ok := g.byToken[token]
	if !ok {
		return nil, "unknown or revoked grant; re-register"
	}
	if g.now().After(grant.ExpiresAt) {
		delete(g.byToken, token)
		return nil, "grant expired; re-register"
	}
	if grant.Ref != ref {
		return nil, "grant is bound to another instance"
	}
	if grant.Session != session {
		return nil, "grant is bound to another session; re-register"
	}
	return grant, ""
}

// RevokeRef revokes every grant for one instance ref (DELETE
// /v1/grants/{ref}), returning how many were live.
func (g *Grants) RevokeRef(ref string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.purgeLocked()
	n := 0
	for token, grant := range g.byToken {
		if grant.Ref == ref {
			delete(g.byToken, token)
			n++
		}
	}
	return n
}

// Active counts live grants (status).
func (g *Grants) Active() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.purgeLocked()
	return len(g.byToken)
}

// TTL exposes the configured grant lifetime.
func (g *Grants) TTL() time.Duration { return g.ttl }
