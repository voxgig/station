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

	// DefaultForwardBodyLimit is §8.5's /v1/forward request-body limit:
	// 32 MB, with a structured station_body_limit beyond it. Streaming
	// uploads are an open question (§18); v1 buffers.
	DefaultForwardBodyLimit = 32 << 20

	// DefaultCaptureMaxEntries / DefaultCaptureMaxBytes bound the capture
	// store: §8.5's 10k entries / 256 MB LRU.
	DefaultCaptureMaxEntries = 10000
	DefaultCaptureMaxBytes   = 256 << 20

	// DefaultCaptureBodyLimit is §8.5's capture-body truncation point:
	// `capture: full` bodies are cut at 64 KB with a truncated marker.
	DefaultCaptureBodyLimit = 64 << 10

	// DefaultGrantTTL is §5.3's grant lifetime: 15m, renewed by
	// re-registration (§3.4).
	DefaultGrantTTL = 15 * time.Minute

	// DefaultPolicyPollTimeout bounds the GET /v1/policy/{ref} long-poll:
	// hold until the policy version changes or this long, then answer
	// with the current view.
	DefaultPolicyPollTimeout = 25 * time.Second

	// DefaultUpstreamTimeout caps one /v1/forward upstream exchange.
	DefaultUpstreamTimeout = 30 * time.Second
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

	// StationConfigPath is the proxy-side station.json (§8.3: the proxy
	// loads profiles ITSELF and derives policy from them, never from
	// registrations). Empty means no proxy-side config: everything stays
	// pending until explicitly approved. main resolves the default via
	// FindStationConfig (cwd upward, then ~/.voxgig/station.json);
	// --config overrides, which is also the test seam.
	StationConfigPath string

	// Profile selects the station.json profile (default "default"; main
	// honors VOXGIG_STATION_PROFILE with the --profile flag winning).
	Profile string

	// StatePath is the approval-state file (§8.3): the blessed
	// base/hosts/name triples - NEVER secret values - persisted beside
	// the token file so approvals survive restart. Empty disables
	// persistence (in-memory approvals only).
	StatePath string

	ForwardBodyLimit  int64
	CaptureMaxEntries int
	CaptureMaxBytes   int64
	CaptureBodyLimit  int
	GrantTTL          time.Duration
	PolicyPollTimeout time.Duration
	UpstreamTimeout   time.Duration

	// The §7 agent gates, both visible in status. AgentWrite arms the
	// daemon half of the mutating-tool gate: a mutating station_call
	// (or replay of a mutating capture) needs BOTH this flag AND the
	// instance's own policy opt-in (`agent: {write: true}`) - writes
	// are a policy grant, not a default (§12). AgentReadDisabled turns
	// the read surface off (agent.read defaults TRUE on a local proxy,
	// §7; the inverted name keeps the zero Config value at the local
	// default). Remote mode will flip the read default (§8.4).
	AgentWrite        bool
	AgentReadDisabled bool

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
	if c.ForwardBodyLimit <= 0 {
		c.ForwardBodyLimit = DefaultForwardBodyLimit
	}
	if c.CaptureMaxEntries <= 0 {
		c.CaptureMaxEntries = DefaultCaptureMaxEntries
	}
	if c.CaptureMaxBytes <= 0 {
		c.CaptureMaxBytes = DefaultCaptureMaxBytes
	}
	if c.CaptureBodyLimit <= 0 {
		c.CaptureBodyLimit = DefaultCaptureBodyLimit
	}
	if c.GrantTTL <= 0 {
		c.GrantTTL = DefaultGrantTTL
	}
	if c.PolicyPollTimeout <= 0 {
		c.PolicyPollTimeout = DefaultPolicyPollTimeout
	}
	if c.UpstreamTimeout <= 0 {
		c.UpstreamTimeout = DefaultUpstreamTimeout
	}
	if c.Profile == "" {
		c.Profile = "default"
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	return c
}
