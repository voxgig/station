// The capture store (design §8.5, §15): an in-memory LRU bounded by
// entry count (default 10k) and total bytes (default 256 MB), truncating
// `capture: full` bodies at 64 KB with a truncated marker. Redaction is
// applied AT CAPTURE TIME, never retroactively (§15): redact-list
// headers, the exchange's transient Station-Redact values, and every
// value the proxy's broker ever resolved are scrubbed before an entry is
// stored, so secret bytes never enter the store at all.
//
// Truncation and redaction make some captures lossy, and a lossy capture
// is not a replayable one (§8.5): each entry records `replayable`, false
// when the request body was truncated or body redaction replaced bytes
// the request needs. REDACTED AUTH HEADERS ARE THE EXCEPTION - replay
// restores those through the credential path (§6), so header redaction
// alone never clears the flag.
package daemon

import (
	"strings"
	"sync"
)

// redactHeaderList is the header redaction list seeded from the debug
// feature's (§1, §15): these header values never enter a capture.
var redactHeaderList = map[string]bool{
	"authorization":   true,
	"cookie":          true,
	"set-cookie":      true,
	"api-key":         true,
	"apikey":          true,
	"x-api-key":       true,
	"idempotency-key": true,
}

// CaptureEntry is one recorded /v1/forward exchange, post-redaction.
type CaptureEntry struct {
	ID      uint64 `json:"id"`
	T       string `json:"t"`
	Session string `json:"session"`
	Plugin  string `json:"plugin"` // instance ref
	Corr    string `json:"corr,omitempty"`
	// Depth is the capture depth actually stored - `full` degrades to
	// `headers` when the envelope carries an unredactable credential
	// (§15's missing-marker rule; Degraded says so).
	Depth    string `json:"depth"`
	Degraded bool   `json:"degraded,omitempty"`

	ReqMethod    string              `json:"reqMethod"`
	ReqURL       string              `json:"reqUrl"`
	ReqHeaders   map[string][]string `json:"reqHeaders,omitempty"`
	ReqBody      string              `json:"reqBody,omitempty"`
	ReqBodyBytes int64               `json:"reqBodyBytes"`
	ReqTruncated bool                `json:"reqTruncated,omitempty"`

	Status       int                 `json:"status"`
	ResHeaders   map[string][]string `json:"resHeaders,omitempty"`
	ResBody      string              `json:"resBody,omitempty"`
	ResBodyBytes int64               `json:"resBodyBytes"`
	ResTruncated bool                `json:"resTruncated,omitempty"`
	DurationMs   int64               `json:"durationMs"`

	Replayable bool   `json:"replayable"`
	Reason     string `json:"reason,omitempty"` // why not replayable

	size int64 // accounting for the byte bound
}

// accounting is the entry's charge against the store's byte bound. It
// counts EVERY retained string, not just the big ones: `Corr` comes
// straight off a client-supplied Station-Corr header and is held for
// the life of the entry, so a fixed metadata estimate would let a
// stream of large correlation ids consume far more memory than
// CaptureMaxBytes reports or enforces. The 128 is what remains: the
// fixed-size fields and the per-entry slice/struct overhead.
func (e *CaptureEntry) accounting() int64 {
	n := int64(len(e.ReqURL) + len(e.ReqBody) + len(e.ResBody) + len(e.Reason) + 128)
	n += int64(len(e.T) + len(e.Session) + len(e.Plugin) + len(e.Corr) +
		len(e.Depth) + len(e.ReqMethod))
	for k, vs := range e.ReqHeaders {
		n += int64(len(k))
		for _, v := range vs {
			n += int64(len(v))
		}
	}
	for k, vs := range e.ResHeaders {
		n += int64(len(k))
		for _, v := range vs {
			n += int64(len(v))
		}
	}
	return n
}

// CaptureStats is the status view (§8.5: bounds visible in status).
type CaptureStats struct {
	Entries    int    `json:"entries"`
	Bytes      int64  `json:"bytes"`
	MaxEntries int    `json:"maxEntries"`
	MaxBytes   int64  `json:"maxBytes"`
	Evicted    uint64 `json:"evicted"`
	Total      uint64 `json:"total"`
	Degraded   uint64 `json:"degraded"`
}

// CaptureStore holds entries in insertion order and evicts oldest-first
// when either bound is exceeded (inserts are the only accesses in this
// phase, so LRU order IS insertion order; the query surface that
// re-touches entries arrives with traffic/replay).
type CaptureStore struct {
	mu         sync.Mutex
	entries    []*CaptureEntry
	bytes      int64
	maxEntries int
	maxBytes   int64
	nextID     uint64
	evicted    uint64
	total      uint64
	degraded   uint64
}

func NewCaptureStore(maxEntries int, maxBytes int64) *CaptureStore {
	if maxEntries <= 0 {
		maxEntries = 1
	}
	if maxBytes <= 0 {
		maxBytes = 1
	}
	return &CaptureStore{maxEntries: maxEntries, maxBytes: maxBytes}
}

// Add stores one entry (already scrubbed by the caller) and evicts
// oldest entries while either bound is exceeded.
func (cs *CaptureStore) Add(e *CaptureEntry) uint64 {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	cs.nextID++
	e.ID = cs.nextID
	e.size = e.accounting()
	cs.entries = append(cs.entries, e)
	cs.bytes += e.size
	cs.total++
	if e.Degraded {
		cs.degraded++
	}
	for len(cs.entries) > 0 &&
		(len(cs.entries) > cs.maxEntries || cs.bytes > cs.maxBytes) {
		old := cs.entries[0]
		cs.entries = cs.entries[1:]
		cs.bytes -= old.size
		cs.evicted++
	}
	return e.ID
}

func (cs *CaptureStore) Stats() CaptureStats {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return CaptureStats{
		Entries:    len(cs.entries),
		Bytes:      cs.bytes,
		MaxEntries: cs.maxEntries,
		MaxBytes:   cs.maxBytes,
		Evicted:    cs.evicted,
		Total:      cs.total,
		Degraded:   cs.degraded,
	}
}

// Snapshot returns the stored entries, oldest first - the seam the
// traffic/replay surface reads from (and the test hook for asserting
// what the store does and does not contain).
func (cs *CaptureStore) Snapshot() []*CaptureEntry {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return append([]*CaptureEntry(nil), cs.entries...)
}

// Query is the cursor-based read over the store (GET /v1/traffic and
// the station_traffic tool): entries with ID > cursor, oldest first,
// filtered by plugin/corr, up to limit. more reports whether matching
// entries remained beyond the limit.
func (cs *CaptureStore) Query(cursor uint64, limit int, plugin string, corr string) (entries []*CaptureEntry, more bool) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for _, e := range cs.entries {
		if e.ID <= cursor {
			continue
		}
		if plugin != "" && e.Plugin != plugin {
			continue
		}
		if corr != "" && e.Corr != corr {
			continue
		}
		if len(entries) >= limit {
			return entries, true
		}
		entries = append(entries, e)
	}
	return entries, false
}

// Find returns the entry with the given id, nil when evicted or never
// recorded.
func (cs *CaptureStore) Find(id uint64) *CaptureEntry {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for _, e := range cs.entries {
		if e.ID == id {
			return e
		}
	}
	return nil
}

// DumpForScan concatenates every stored string field - the surface the
// "secret bytes appear nowhere" guarantee is checked against.
func (cs *CaptureStore) DumpForScan() string {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	var b strings.Builder
	for _, e := range cs.entries {
		b.WriteString(e.T)
		b.WriteString(e.Session)
		b.WriteString(e.Plugin)
		b.WriteString(e.Corr)
		b.WriteString(e.ReqMethod)
		b.WriteString(e.ReqURL)
		b.WriteString(e.ReqBody)
		b.WriteString(e.ResBody)
		b.WriteString(e.Reason)
		for k, vs := range e.ReqHeaders {
			b.WriteString(k)
			for _, v := range vs {
				b.WriteString(v)
			}
		}
		for k, vs := range e.ResHeaders {
			b.WriteString(k)
			for _, v := range vs {
				b.WriteString(v)
			}
		}
	}
	return b.String()
}

// scrubText replaces each of values in text, exact match, no length
// floor (§7: on this boundary the promise is absolute). Reports whether
// anything was replaced.
func scrubText(text string, values []string) (string, bool) {
	changed := false
	for _, v := range values {
		if v == "" {
			continue
		}
		if strings.Contains(text, v) {
			text = strings.ReplaceAll(text, v, redactedMarker)
			changed = true
		}
	}
	return text, changed
}

// scrubHeaders copies headers with redact-list and named-credential
// values replaced, and every scrub value removed from any header value.
// names are additional lowercased header names to redact (the
// exchange's Station-Redact set).
func scrubHeaders(headers map[string][]string, names map[string]bool, values []string) map[string][]string {
	if headers == nil {
		return nil
	}
	out := make(map[string][]string, len(headers))
	for k, vs := range headers {
		lk := strings.ToLower(k)
		cp := make([]string, len(vs))
		for i, v := range vs {
			if redactHeaderList[lk] || names[lk] {
				cp[i] = redactedMarker
				continue
			}
			cp[i], _ = scrubText(v, values)
		}
		out[k] = cp
	}
	return out
}
