package daemon

import "sync"

// Ring is the bounded in-memory event store (§8.5): fixed capacity,
// overflow drops oldest, drop counts visible in status (§6). Entries are
// stored as the raw NDJSON lines received - the StationEvent schema
// evolves additively and unknown fields must survive (§6), so the proxy
// never re-serializes what it stores.
type Ring struct {
	mu      sync.Mutex
	buf     [][]byte
	head    int // index of the oldest entry
	size    int
	total   uint64 // entries ever pushed
	dropped uint64 // entries evicted by overflow
}

// RingStats is the status view of the ring (§8.5: bounds and fill are
// visible in status).
type RingStats struct {
	Capacity int    `json:"capacity"`
	Size     int    `json:"size"`
	Total    uint64 `json:"total"`
	Dropped  uint64 `json:"dropped"`
}

func NewRing(capacity int) *Ring {
	if capacity <= 0 {
		capacity = 1
	}
	return &Ring{buf: make([][]byte, capacity)}
}

// Push appends line, evicting the oldest entry when full. The caller
// must hand over an immutable slice (the server copies scanner-owned
// bytes before pushing).
func (r *Ring) Push(line []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.size == len(r.buf) {
		r.buf[r.head] = line
		r.head = (r.head + 1) % len(r.buf)
		r.dropped++
	} else {
		r.buf[(r.head+r.size)%len(r.buf)] = line
		r.size++
	}
	r.total++
}

// Snapshot returns the buffered lines, oldest first. Unused by the v1
// endpoints (tap is live-only); the seam a later traffic/query surface
// reads from.
func (r *Ring) Snapshot() [][]byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([][]byte, 0, r.size)
	for i := 0; i < r.size; i++ {
		out = append(out, r.buf[(r.head+i)%len(r.buf)])
	}
	return out
}

func (r *Ring) Stats() RingStats {
	r.mu.Lock()
	defer r.mu.Unlock()
	return RingStats{Capacity: len(r.buf), Size: r.size, Total: r.total, Dropped: r.dropped}
}

// Hub fans events out to live tap subscribers (GET /v1/tap). Publishing
// never blocks: a subscriber whose buffer is full loses that event and
// the loss is counted - ingest must never wait on a slow consumer (§6).
type Hub struct {
	mu      sync.Mutex
	subs    map[uint64]*tapSub
	nextID  uint64
	buffer  int
	dropped uint64
}

type tapSub struct {
	ch     chan []byte
	plugin string // optional filter: only events whose plugin matches
}

func NewHub(buffer int) *Hub {
	if buffer <= 0 {
		buffer = 1
	}
	return &Hub{subs: map[uint64]*tapSub{}, buffer: buffer}
}

// Subscribe registers a tap consumer. plugin narrows the stream to one
// instance name ("" for everything).
func (h *Hub) Subscribe(plugin string) (uint64, <-chan []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	id := h.nextID
	h.nextID++
	sub := &tapSub{ch: make(chan []byte, h.buffer), plugin: plugin}
	h.subs[id] = sub
	return id, sub.ch
}

func (h *Hub) Unsubscribe(id uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.subs, id)
}

// Publish delivers line to every matching subscriber, dropping (and
// counting) where a buffer is full.
func (h *Hub) Publish(line []byte, plugin string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, sub := range h.subs {
		if sub.plugin != "" && sub.plugin != plugin {
			continue
		}
		select {
		case sub.ch <- line:
		default:
			h.dropped++
		}
	}
}

// Stats returns the subscriber count and cumulative per-subscriber drops.
func (h *Hub) Stats() (subscribers int, dropped uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs), h.dropped
}
