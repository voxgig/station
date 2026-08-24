// R2 grants (design §5.3; decision D-2026-08-24-1): a grant is a token
// bound to the registration session, scoped PER INSTANCE - not per api -
// TTL'd (default 15m), renewed by re-registration (§3.4), revocable via
// DELETE /v1/grants/{ref}. Revoking one instance never touches its
// siblings on the same api. The grant authorizes the proxy to inject
// that instance's credential on the outbound hop; the application
// process never holds the value.
package daemon

import (
	"sync"
	"time"
)

type Grant struct {
	Token     string
	Ref       string // instance ref (D-2026-08-24-1: per instance)
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

// Issue mints a grant for one instance registration. Re-registration
// simply issues a fresh grant (§3.4: grants renew by re-registration);
// the old one ages out on its TTL.
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

// Validate checks a presented grant token for an instance. The reason
// distinguishes the failure for the error message; all failures are
// station_grant_expired on the wire (§14: the grant is gone and
// re-registration is the remedy in every case).
func (g *Grants) Validate(token string, ref string) (*Grant, string) {
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
