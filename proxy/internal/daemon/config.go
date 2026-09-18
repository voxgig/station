package daemon

import "time"

const Version = "0.1.0"

const Protocol = 1

const (
	DefaultListen = "127.0.0.1:8299"

	DefaultRingCapacity = 10000

	DefaultSessionTTL = 5 * time.Minute

	DefaultRegisterBodyLimit = 1 << 20

	DefaultEventsBodyLimit = 8 << 20

	DefaultEventLineLimit = 256 << 10

	// DefaultTapBuffer is the per-subscriber tap channel depth; a slow
	// tap consumer drops (counted), never blocks ingest (§6: events
	// never delay an operation).
	DefaultTapBuffer = 256

	// DefaultForwardBodyLimit is §8.5's /v1/forward request-body limit:
	// 32 MB, with a structured station_body_limit beyond it. Streaming
	// uploads are an open question (§18); v1 buffers.
	DefaultForwardBodyLimit = 32 << 20

	DefaultCaptureMaxEntries = 10000
	DefaultCaptureMaxBytes   = 256 << 20

	DefaultCaptureBodyLimit = 64 << 10

	DefaultGrantTTL = 15 * time.Minute

	DefaultPolicyPollTimeout = 25 * time.Second

	DefaultUpstreamTimeout = 30 * time.Second
)

type Config struct {
	Listen string

	TokenPath string

	SessionTTL        time.Duration
	RingCapacity      int
	RegisterBodyLimit int64
	EventsBodyLimit   int64
	EventLineLimit    int
	TapBuffer         int

	StationConfigPath string

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

	AgentWrite        bool
	AgentReadDisabled bool

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
