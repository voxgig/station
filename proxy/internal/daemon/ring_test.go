package daemon

import (
	"fmt"
	"testing"
)

func TestRingEviction(t *testing.T) {
	r := NewRing(3)

	for i := 0; i < 5; i++ {
		r.Push([]byte(fmt.Sprintf("e%d", i)))
	}

	st := r.Stats()
	if st.Capacity != 3 || st.Size != 3 || st.Total != 5 || st.Dropped != 2 {
		t.Errorf("stats = %+v, want capacity 3 size 3 total 5 dropped 2", st)
	}

	// §8.5/§6: overflow drops oldest - the survivors are the newest
	// three, oldest first.
	snap := r.Snapshot()
	want := []string{"e2", "e3", "e4"}
	if len(snap) != len(want) {
		t.Fatalf("snapshot len = %d, want %d", len(snap), len(want))
	}
	for i, w := range want {
		if string(snap[i]) != w {
			t.Errorf("snapshot[%d] = %s, want %s", i, snap[i], w)
		}
	}
}

func TestHubFilterAndDrop(t *testing.T) {
	h := NewHub(1)

	_, all := h.Subscribe("")
	_, onlyA := h.Subscribe("a")

	h.Publish([]byte("ev-a"), "a")
	h.Publish([]byte("ev-b"), "b") // fills `all`'s depth-1 buffer -> dropped there

	if got := string(<-all); got != "ev-a" {
		t.Errorf("all sub got %q, want ev-a", got)
	}
	if got := string(<-onlyA); got != "ev-a" {
		t.Errorf("filtered sub got %q, want ev-a", got)
	}
	select {
	case extra := <-onlyA:
		t.Errorf("filtered sub leaked %q", extra)
	default:
	}

	// The b event overflowed `all` (depth 1, unread at publish time) and
	// was counted, never blocking the publisher (§6).
	subs, dropped := h.Stats()
	if subs != 2 {
		t.Errorf("subscribers = %d, want 2", subs)
	}
	if dropped != 1 {
		t.Errorf("dropped = %d, want 1", dropped)
	}
}

func TestHubUnsubscribe(t *testing.T) {
	h := NewHub(4)
	id, _ := h.Subscribe("")
	h.Unsubscribe(id)
	h.Publish([]byte("ev"), "")
	subs, dropped := h.Stats()
	if subs != 0 || dropped != 0 {
		t.Errorf("after unsubscribe: subs %d dropped %d, want 0 0", subs, dropped)
	}
}
