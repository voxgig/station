// The solo event surface (design §6): a bounded ring buffer plus a live
// tap with serialized callbacks. Events never fail an operation; overflow
// drops oldest and the drop count is visible in Status().
//
// A port of typescript/src/events.ts, which is canonical. StationEvent's
// shape is pinned by the design's §6 schema; unknown fields are ignored
// by consumers, so it evolves additively.
package station

import "sync"

// Event is StationEvent v1 (design §6).
type Event struct {
	T int64 `json:"t"`
	// Plugin is the INSTANCE; API is what groups its siblings. §7.3's
	// grouping contract wants BOTH on EVERY kind: construction events
	// carrying both while runtime events carried only one is grouping
	// that works exactly until it is used.
	Plugin string         `json:"plugin,omitempty"`
	API    string         `json:"api,omitempty"`
	Corr   string         `json:"corr,omitempty"`
	Kind   string         `json:"kind"` // construct | op | http | error | feature | station
	Op     *OpEvent       `json:"op,omitempty"`
	HTTP   *HTTPEvent     `json:"http,omitempty"`
	Err    *ErrEvent      `json:"err,omitempty"`
	Meta   map[string]any `json:"meta,omitempty"`
}

type OpEvent struct {
	Entity     string `json:"entity"`
	Op         string `json:"op"`
	Outcome    string `json:"outcome"`
	DurationMs int64  `json:"durationMs"`
}

type HTTPEvent struct {
	Method     string `json:"method"`
	Host       string `json:"host"`
	Path       string `json:"path"`
	Status     int    `json:"status"`
	DurationMs int64  `json:"durationMs"`
	Bytes      int64  `json:"bytes"`
}

type ErrEvent struct {
	Code    string `json:"code,omitempty"`
	Status  int    `json:"status,omitempty"`
	Message string `json:"message"`
}

// EventBufferStatus is the Status() view of the buffer.
type EventBufferStatus struct {
	Buffered int `json:"buffered"`
	Dropped  int `json:"dropped"`
}

type eventBuffer struct {
	mu    sync.Mutex
	ring  []Event
	max   int
	drops int
	taps  []*tapEntry
}

type tapEntry struct {
	fn func(Event)
}

func newEventBuffer(max int) *eventBuffer {
	if 0 >= max {
		max = 1000
	}
	return &eventBuffer{max: max}
}

func (buffer *eventBuffer) emit(event Event) {
	buffer.mu.Lock()
	buffer.ring = append(buffer.ring, event)
	if len(buffer.ring) > buffer.max {
		buffer.ring = buffer.ring[1:]
		buffer.drops++
	}
	taps := make([]*tapEntry, len(buffer.taps))
	copy(taps, buffer.taps)
	buffer.mu.Unlock()

	// Serialized (one emit at a time per buffer lock ordering), and a
	// panicking tap must not fail the operation that emitted the event.
	for _, tap := range taps {
		callTap(tap.fn, event)
	}
}

func callTap(fn func(Event), event Event) {
	defer func() { _ = recover() }()
	fn(event)
}

func (buffer *eventBuffer) events() []Event {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	out := make([]Event, len(buffer.ring))
	copy(out, buffer.ring)
	return out
}

func (buffer *eventBuffer) tap(fn func(Event)) func() {
	entry := &tapEntry{fn: fn}
	buffer.mu.Lock()
	buffer.taps = append(buffer.taps, entry)
	buffer.mu.Unlock()

	return func() {
		buffer.mu.Lock()
		defer buffer.mu.Unlock()
		for i, one := range buffer.taps {
			if one == entry {
				buffer.taps = append(buffer.taps[:i], buffer.taps[i+1:]...)
				return
			}
		}
	}
}

func (buffer *eventBuffer) status() EventBufferStatus {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return EventBufferStatus{Buffered: len(buffer.ring), Dropped: buffer.drops}
}
