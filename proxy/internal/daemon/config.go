package daemon

import "time"

// Version is the proxy's own release version, reported by /v1/health and
// /v1/status. Independent of the wire protocol version (§8.6: the five
// artifacts version independently).
const Version = "0.1.0"

// Protocol is the wire protocol version this daemon speaks (§8).
const Protocol = 1

// Named defaults - all configurable, all visible in /v1/status (§8.5).
const (
	// DefaultListen is §8.1's loopback TCP default.
	DefaultListen = "127.0.0.1:8299"

	// DefaultRingCapacity bounds the in-memory event ring. §8.5 names
	// 10k entries as the proxy store default.
	DefaultRingCapacity = 10000

	// DefaultSessionTTL is the session liveness window. §3.4 pins
	// expiry-on-TTL with liveness piggybacking on /v1/events batches but
	// does not pin the value; 5m comfortably covers any sane library
	// flush interval while keeping `status` free of ghosts.
	DefaultSessionTTL = 5 * time.Minute

	// DefaultRegisterBodyLimit caps a /v1/register body. A descriptor is
	// config-derived metadata; 1 MiB is generous. (§8.5's 32 MB figure is
	// the /v1/forward request-body limit - a later phase.)
	DefaultRegisterBodyLimit = 1 << 20

	// DefaultEventsBodyLimit caps one /v1/events NDJSON batch.
	DefaultEventsBodyLimit = 8 << 20

	// DefaultEventLineLimit caps one event line within a batch.
	DefaultEventLineLimit = 256 << 10

	// DefaultTapBuffer is the per-subscriber tap channel depth; a slow
	// tap consumer drops (counted), never blocks ingest (§6: events
	// never delay an operation).
	DefaultTapBuffer = 256
)

// Config carries the daemon's tunables. The zero value is usable:
// withDefaults fills every unset field.
type Config struct {
	// Listen is the bound address (host:port) the daemon serves on. It
	// also seeds the Host/Origin allowlist (§8.1), so it must be the
	// *actual* bound address - callers that listen on :0 pass the
	// resolved address.
	Listen string

	// TokenPath is the token file location. Informational here (the
	// caller loads the token); surfaced so status/logs can name it.
	TokenPath string

	SessionTTL        time.Duration
	RingCapacity      int
	RegisterBodyLimit int64
	EventsBodyLimit   int64
	EventLineLimit    int
	TapBuffer         int

	// Now is the clock; tests inject a fake. Defaults to time.Now.
	Now func() time.Time
}

func (c Config) withDefaults() Config {
	if c.Listen == "" {
		c.Listen = DefaultListen
	}
	if c.SessionTTL <= 0 {
		c.SessionTTL = DefaultSessionTTL
	}
	if c.RingCapacity <= 0 {
		c.RingCapacity = DefaultRingCapacity
	}
	if c.RegisterBodyLimit <= 0 {
		c.RegisterBodyLimit = DefaultRegisterBodyLimit
	}
	if c.EventsBodyLimit <= 0 {
		c.EventsBodyLimit = DefaultEventsBodyLimit
	}
	if c.EventLineLimit <= 0 {
		c.EventLineLimit = DefaultEventLineLimit
	}
	if c.TapBuffer <= 0 {
		c.TapBuffer = DefaultTapBuffer
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	return c
}
