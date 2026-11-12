package station

import "testing"

// A sweep under load moves stale operations aside; one that is still
// running emits when it ends.
func TestAnEvictedOperationStillEmitsOnce(t *testing.T) {
	st, err := New(&Options{NoConfig: true, Config: map[string]any{
		"station": 1, "profiles": map[string]any{"default": map[string]any{}},
	}})
	if nil != err {
		t.Fatal(err)
	}
	type key struct{ int }
	old := &key{-1}
	st.mu.Lock()
	st.ops[old] = &opState{corr: "c-old", start: nowMs() - 400_000}
	for i := 0; i < 4096; i++ {
		st.ops[&key{i}] = &opState{corr: "c", start: nowMs()}
	}
	st.mu.Unlock()

	st.opStart(&key{4096})
	if _, live := st.ops[old]; live {
		t.Fatal("the sweep kept an operation over five minutes old")
	}

	info := OpInfo{Entity: "note", Op: "load", Outcome: "ok"}
	st.opEvent("pad", old, info, "ok")
	st.opEvent("pad", old, info, "unexpected")
	var ops []Event
	for _, ev := range st.Events() {
		if "op" == ev.Kind {
			ops = append(ops, ev)
		}
	}
	if 1 != len(ops) || "c-old" != ops[0].Corr {
		t.Fatalf("want one op event on c-old, got %+v", ops)
	}
}
