// RUN: make test
// RUN-SOME: go test -run 'TestBind'
//
// Focused unit tests for the parts the JSON corpus cannot express: the
// binding (wrap position, placeholder placement, copy-on-inject, mock
// non-injection, miss-vs-error), the ambient instance, the event ring,
// and the exact-value scrub. A miniature fake of the generated seam
// stands in for a real SDK; the true generated adapter is exercised by
// the end-to-end consumer flow (design §13).

package station_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/voxgig/station/go/station"
)

// --- a miniature generated-SDK seam ---

type fakeClient struct {
	mode    string
	fetcher station.TransportFunc
}

func fakeConfig(slug string, name string, auth bool) map[string]any {
	options := map[string]any{
		"base":   "http://localhost:8920",
		"entity": map[string]any{"todo": map[string]any{}},
	}
	if auth {
		options["auth"] = map[string]any{"prefix": ""}
	}
	return map[string]any{
		"main": map[string]any{
			"name": name, "slug": slug, "version": "0.0.1", "target": "go",
		},
		"feature": map[string]any{"station": map[string]any{}, "test": map[string]any{}},
		"options": options,
		"entity": map[string]any{
			"todo": map[string]any{
				"fields": []any{map[string]any{"name": "title", "kind": "String"}},
				"op": map[string]any{
					"list": map[string]any{"points": []any{map[string]any{
						"method": "GET", "orig": "/api/todo", "parts": []any{"api", "todo"},
					}}},
				},
			},
		},
	}
}

type harness struct {
	client  *fakeClient
	options map[string]any
	binding *station.FeatureBinding
}

// bindOne runs the adapter's Init-time translation against a station,
// mirroring the generated tm/go template exactly.
func bindOne(t *testing.T, st *station.Station, slug string,
	names []string, base station.TransportFunc, resident string) *harness {
	t.Helper()

	client := &fakeClient{mode: "live", fetcher: base}
	options := map[string]any{"apikey": resident, "feature": map[string]any{}}

	fopts := map[string]any{"active": true, "calleropts": map[string]any{}}
	if nil != st {
		fopts["station"] = st
	}
	options["feature"].(map[string]any)["station"] = fopts

	inner := client.fetcher
	binding := station.Bind(&station.BindSpec{
		Client:       client,
		Config:       fakeConfig(slug, "FakeSDK", true),
		SDKOptions:   options,
		FeatureOpts:  fopts,
		FeatureNames: names,
		Mode:         func() string { return client.mode },
		Fetch: func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
			return inner(opctx, fullurl, fetchdef)
		},
		SetFetch: func(next station.TransportFunc) {
			client.fetcher = next
		},
	})

	return &harness{client: client, options: options, binding: binding}
}

func okResponse() station.TransportFunc {
	return func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
		return map[string]any{
			"status":  200,
			"headers": map[string]any{"content-length": "12"},
		}, nil
	}
}

func newStation(t *testing.T, values map[string]string) *station.Station {
	t.Helper()
	st, err := station.New(&station.Options{
		NoConfig: true,
		Config: map[string]any{
			"station": 1,
			"profiles": map[string]any{
				"default": map[string]any{
					"secrets": map[string]any{"providers": []any{
						map[string]any{"kind": "memory", "values": values},
					}},
				},
			},
		},
	})
	if nil != err {
		t.Fatalf("station: %v", err)
	}
	return st
}

func filterEvents(events []station.Event, kind string) []station.Event {
	out := []station.Event{}
	for _, event := range events {
		if kind == event.Kind {
			out = append(out, event)
		}
	}
	return out
}

func expectPanicCode(t *testing.T, code string, run func()) {
	t.Helper()
	defer func() {
		recovered := recover()
		if nil == recovered {
			t.Fatalf("expected panic %s", code)
		}
		serr, is := recovered.(*station.Error)
		if !is || code != serr.Code {
			t.Fatalf("expected %s, got %v", code, recovered)
		}
	}()
	run()
}

// --- the binding ---

func TestBindInjectsAndStaysPlaceholderSafe(t *testing.T) {
	st := newStation(t, map[string]string{"FAKEPAD_APIKEY": "real-key-1"})

	var seen map[string]any
	base := func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
		seen = fetchdef
		return okResponse()(opctx, fullurl, fetchdef)
	}

	h := bindOne(t, st, "fakepad", []string{"station"}, base, "")
	if nil == h.binding {
		t.Fatal("expected a binding")
	}

	// The placeholder was planted at bind time (design §5.3 R1).
	if "[station:fakepad]" != h.options["apikey"] {
		t.Fatalf("placeholder not planted: %v", h.options["apikey"])
	}

	// A prepared fetchdef carries the placeholder; the wire gets the
	// real value; the caller's fetchdef object never does
	// (copy-on-inject).
	fetchdef := map[string]any{
		"method":  "GET",
		"headers": map[string]any{"authorization": "[station:fakepad]"},
	}
	type opctxkey struct{ int }
	opctx := &opctxkey{}
	h.binding.PrePoint(opctx)
	if _, err := h.client.fetcher(opctx, "http://localhost:8920/api/todo", fetchdef); nil != err {
		t.Fatal(err)
	}
	if "real-key-1" != seen["headers"].(map[string]any)["authorization"] {
		t.Fatalf("injection missed: %v", seen["headers"])
	}
	if "[station:fakepad]" != fetchdef["headers"].(map[string]any)["authorization"] {
		t.Fatalf("copy-on-inject violated: %v", fetchdef["headers"])
	}
	h.binding.PreDone(opctx, station.OpInfo{Entity: "todo", Op: "list", Outcome: "ok"})

	// Correlated op + http events (design §3 item 3).
	events := st.Events()
	https := filterEvents(events, "http")
	ops := filterEvents(events, "op")
	if 1 != len(https) || 1 != len(ops) {
		t.Fatalf("expected 1 http + 1 op event, got %d + %d", len(https), len(ops))
	}
	if "" == https[0].Corr || https[0].Corr != ops[0].Corr {
		t.Fatalf("uncorrelated: %q vs %q", https[0].Corr, ops[0].Corr)
	}
	if 200 != https[0].HTTP.Status || 12 != https[0].HTTP.Bytes {
		t.Fatalf("http event wrong: %+v", https[0].HTTP)
	}
	if "ok" != ops[0].Op.Outcome || "todo" != ops[0].Op.Entity {
		t.Fatalf("op event wrong: %+v", ops[0].Op)
	}

	// No event holds the real value.
	dump, _ := json.Marshal(events)
	if strings.Contains(string(dump), "real-key-1") {
		t.Fatal("credential leaked into events")
	}
}

func TestMockModeNeverInjects(t *testing.T) {
	st := newStation(t, map[string]string{"FAKEPAD_APIKEY": "real-key-2"})

	var seen map[string]any
	base := func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
		seen = fetchdef
		return okResponse()(opctx, fullurl, fetchdef)
	}

	h := bindOne(t, st, "fakepad", []string{"test", "station"}, base, "")
	h.client.mode = "test"

	fetchdef := map[string]any{
		"headers": map[string]any{"authorization": "[station:fakepad]"},
	}
	if _, err := h.client.fetcher(nil, "http://localhost:8920/api/todo", fetchdef); nil != err {
		t.Fatal(err)
	}

	// The placeholder rode through untouched: real credentials never
	// enter in-memory mock stores (design §3.3) - but the http event
	// still saw the mock attempt.
	if "[station:fakepad]" != seen["headers"].(map[string]any)["authorization"] {
		t.Fatalf("mock transport saw an injected value: %v", seen["headers"])
	}
	if 1 != len(filterEvents(st.Events(), "http")) {
		t.Fatal("expected the mock attempt as an http event")
	}
}

func TestMissingSecretFailsOnTheOpPath(t *testing.T) {
	st := newStation(t, map[string]string{})

	h := bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")

	_, err := h.client.fetcher(nil, "http://localhost:8920/api/todo",
		map[string]any{"headers": map[string]any{"authorization": "[station:fakepad]"}})
	serr, is := err.(*station.Error)
	if !is || "station_secret_no_value" != serr.Code {
		t.Fatalf("expected station_secret_no_value, got %v", err)
	}

	errs := filterEvents(st.Events(), "error")
	if 1 != len(errs) || "station_secret_no_value" != errs[0].Err.Code {
		t.Fatalf("expected one station_secret_no_value error event: %+v", errs)
	}
}

func TestStoreErrorIsNotAMiss(t *testing.T) {
	// A chain whose store COULD NOT ANSWER must raise
	// station_secret_error, never fall through (design §5.2). An
	// unreachable vault stands in via a hashicorp provider pointing at
	// a closed port.
	st, err := station.New(&station.Options{
		NoConfig: true,
		Config: map[string]any{
			"station": 1,
			"profiles": map[string]any{
				"default": map[string]any{
					"secrets": map[string]any{"providers": []any{
						map[string]any{"kind": "hashicorp",
							"addr": "https://127.0.0.1:1", "token": "t"},
					}},
				},
			},
		},
	})
	if nil != err {
		t.Fatal(err)
	}

	h := bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")

	_, ferr := h.client.fetcher(nil, "http://localhost:8920/api/todo",
		map[string]any{"headers": map[string]any{"authorization": "[station:fakepad]"}})
	serr, is := ferr.(*station.Error)
	if !is || "station_secret_error" != serr.Code {
		t.Fatalf("expected station_secret_error, got %v", ferr)
	}
}

func TestHoistOfResidentCredential(t *testing.T) {
	st := newStation(t, map[string]string{})

	var seen map[string]any
	base := func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
		seen = fetchdef
		return okResponse()(opctx, fullurl, fetchdef)
	}

	h := bindOne(t, st, "fakepad", []string{"station"}, base, "resident-key-3")

	if "[station:fakepad]" != h.options["apikey"] {
		t.Fatalf("resident credential not replaced: %v", h.options["apikey"])
	}

	warns := 0
	for _, event := range filterEvents(st.Events(), "station") {
		if warn, _ := event.Meta["warn"].(string); strings.Contains(warn, "hoisted") {
			warns++
		}
	}
	if 1 != warns {
		t.Fatalf("expected one hoist warning, got %d", warns)
	}

	// The hoisted value is what injection uses - and the scrub hides it.
	if _, err := h.client.fetcher(nil, "http://localhost:8920/api/todo",
		map[string]any{"headers": map[string]any{"authorization": "[station:fakepad]"}}); nil != err {
		t.Fatal(err)
	}
	if "resident-key-3" != seen["headers"].(map[string]any)["authorization"] {
		t.Fatalf("hoisted value not injected: %v", seen["headers"])
	}
	if "[redacted]" != st.Redact("resident-key-3") {
		t.Fatal("hoisted value not scrubbed")
	}
}

func TestWrapOrderGuard(t *testing.T) {
	st := newStation(t, map[string]string{})
	expectPanicCode(t, "station_wrap_order", func() {
		bindOne(t, st, "fakepad", []string{"test", "retry", "station"}, okResponse(), "")
	})
}

func TestBoundTwice(t *testing.T) {
	st := newStation(t, map[string]string{})

	h := bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")
	if nil == h.binding {
		t.Fatal("expected a binding")
	}

	// A genuinely second client of the same SDK fails the slug check.
	expectPanicCode(t, "station_bound_twice", func() {
		bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")
	})
}

func TestSecondArrivalSameClientIsInert(t *testing.T) {
	st := newStation(t, map[string]string{})

	client := &fakeClient{mode: "live", fetcher: okResponse()}
	options := map[string]any{"apikey": "", "feature": map[string]any{}}
	fopts := map[string]any{"active": true, "station": st}
	options["feature"].(map[string]any)["station"] = fopts

	spec := &station.BindSpec{
		Client: client, Config: fakeConfig("fakepad", "FakeSDK", true),
		SDKOptions: options, FeatureOpts: fopts,
		FeatureNames: []string{"station"},
		Mode:         func() string { return client.mode },
		Fetch:        client.fetcher,
		SetFetch:     func(next station.TransportFunc) { client.fetcher = next },
	}

	if nil == station.Bind(spec) {
		t.Fatal("expected a binding")
	}
	if nil != station.Bind(spec) {
		t.Fatal("second arrival for the same client must be inert")
	}
	if 1 != len(filterEvents(st.Events(), "construct")) {
		t.Fatal("expected exactly one construct event")
	}
}

func TestNoOpenStationIsInert(t *testing.T) {
	station.Reset()
	h := bindOne(t, nil, "fakepad", []string{"station"}, okResponse(), "")
	if nil != h.binding {
		t.Fatal("expected an inert nil binding with no station open")
	}
	// The options were never touched.
	if "" != h.options["apikey"] {
		t.Fatalf("inert binding mutated options: %v", h.options["apikey"])
	}
}

func TestHostsPolicy(t *testing.T) {
	st, err := station.New(&station.Options{
		NoConfig: true,
		Config: map[string]any{
			"station": 1,
			"profiles": map[string]any{
				"default": map[string]any{
					"secrets": map[string]any{"providers": []any{
						map[string]any{"kind": "memory",
							"values": map[string]string{"FAKEPAD_APIKEY": "k"}},
					}},
					"sdk": map[string]any{
						"fakepad": map[string]any{
							"policy": map[string]any{"hosts": []any{"localhost"}},
						},
					},
				},
			},
		},
	})
	if nil != err {
		t.Fatal(err)
	}

	var seen map[string]any
	base := func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
		seen = fetchdef
		return okResponse()(opctx, fullurl, fetchdef)
	}
	h := bindOne(t, st, "fakepad", []string{"station"}, base, "")

	// On-list egress passes, and rides with manual redirects (§8.2's
	// rule at the library seam).
	if _, err := h.client.fetcher(nil, "http://localhost:8920/api/todo",
		map[string]any{"headers": map[string]any{}}); nil != err {
		t.Fatal(err)
	}
	if "manual" != seen["redirect"] {
		t.Fatalf("expected redirect manual under a hosts policy: %v", seen["redirect"])
	}

	// Off-list egress is denied before the transport runs.
	seen = nil
	_, ferr := h.client.fetcher(nil, "http://evil.example/api/todo",
		map[string]any{"headers": map[string]any{}})
	serr, is := ferr.(*station.Error)
	if !is || "station_host_allow" != serr.Code {
		t.Fatalf("expected station_host_allow, got %v", ferr)
	}
	if nil != seen {
		t.Fatal("denied request reached the transport")
	}
}

func TestRequireProxyFailsOnTheOpPath(t *testing.T) {
	st, err := station.New(&station.Options{NoConfig: true, Proxy: "require"})
	if nil != err {
		t.Fatal(err)
	}

	// Construction succeeded (§2.1: open is non-blocking; fail-closed
	// means traffic) - the operation fails.
	h := bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")
	_, ferr := h.client.fetcher(nil, "http://localhost:8920/api/todo",
		map[string]any{"headers": map[string]any{}})
	serr, is := ferr.(*station.Error)
	if !is || "station_no_proxy" != serr.Code {
		t.Fatalf("expected station_no_proxy, got %v", ferr)
	}
}

// --- the ambient instance (design §10.2) ---

func TestAmbientOpenIsIdempotentAndConflictChecked(t *testing.T) {
	station.Reset()
	defer station.Reset()

	st := station.Open(&station.Options{NoConfig: true})
	if st != station.Open(&station.Options{NoConfig: true}) {
		t.Fatal("open must be idempotent")
	}
	if st != station.Current() {
		t.Fatal("current must return the ambient instance")
	}

	expectPanicCode(t, "station_open_conflict", func() {
		station.Open(&station.Options{NoConfig: true, Profile: "prod"})
	})

	st.Close()
	if nil != station.Current() {
		t.Fatal("close of the ambient instance must reset it")
	}
}

// --- events (design §6) ---

func TestEventRingDropsOldestAndTapsSerialize(t *testing.T) {
	st := newStation(t, map[string]string{"FAKEPAD_APIKEY": "k"})
	h := bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")

	tapped := 0
	unsub := st.Tap(func(event station.Event) { tapped++ })
	panicky := st.Tap(func(event station.Event) { panic("tap gone wrong") })
	defer panicky()

	for i := 0; i < 1200; i++ {
		if _, err := h.client.fetcher(nil, "http://localhost:8920/api/todo",
			map[string]any{"headers": map[string]any{}}); nil != err {
			t.Fatal(err)
		}
	}
	unsub()

	status := st.Status()
	if 1000 != status.Events.Buffered {
		t.Fatalf("ring must cap at 1000, got %d", status.Events.Buffered)
	}
	if 0 >= status.Events.Dropped {
		t.Fatal("drops must be counted")
	}
	if 1200 > tapped {
		t.Fatalf("tap missed events: %d", tapped)
	}
	if "solo" != status.Mode {
		t.Fatalf("status mode: %s", status.Mode)
	}
}

// --- the scrub (design §7 as revised) ---

func TestScrubHasNoLengthFloor(t *testing.T) {
	st := newStation(t, map[string]string{"FAKEPAD_APIKEY": "xy"})
	h := bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")

	// Resolve the two-character value into the broker.
	if _, err := h.client.fetcher(nil, "http://localhost:8920/api/todo",
		map[string]any{"headers": map[string]any{"authorization": "[station:fakepad]"}}); nil != err {
		t.Fatal(err)
	}

	// sekreto's own Redact has a 4-char readability floor; station's
	// boundary promise is absolute (design §7).
	if "the [redacted] value" != st.Redact("the xy value") {
		t.Fatalf("short value survived the scrub: %q", st.Redact("the xy value"))
	}
}

// --- close (design §11) ---

func TestCloseWarnsOnUnmatchedProfilePluginKeys(t *testing.T) {
	st, err := station.New(&station.Options{
		NoConfig: true,
		Config: map[string]any{
			"station": 1,
			"profiles": map[string]any{
				"default": map[string]any{
					"sdk": map[string]any{"typod": map[string]any{"base": "http://x"}},
				},
			},
		},
	})
	if nil != err {
		t.Fatal(err)
	}

	st.Close()
	st.Close() // idempotent

	warned := 0
	for _, event := range filterEvents(st.Events(), "station") {
		if warn, _ := event.Meta["warn"].(string); strings.Contains(warn, "typod") {
			warned++
		}
	}
	if 1 != warned {
		t.Fatalf("expected one unmatched-plugin warning, got %d", warned)
	}
}

// --- the inverted binding options (design §3.1) ---

func TestOptionsBuildsTheActivationEntry(t *testing.T) {
	st := newStation(t, map[string]string{})

	opts := st.Options(map[string]any{"base": "http://x"})
	fopts, _ := opts["feature"].(map[string]any)["station"].(map[string]any)
	if true != fopts["active"] {
		t.Fatal("activation entry missing")
	}
	if st != fopts["station"] {
		t.Fatal("handle missing")
	}
	if "http://x" != fopts["calleropts"].(map[string]any)["base"] {
		t.Fatal("calleropts missing")
	}
	if "http://x" != opts["base"] {
		t.Fatal("caller opts must ride through")
	}

	// Nil extra works for the two-line quickstart.
	bare := st.Options(nil)
	if nil == bare["feature"] {
		t.Fatal("bare options must carry the activation entry")
	}
}

// --- base precedence (design §3.5) ---

func TestProfileBaseAppliesWhenCallerSetsNone(t *testing.T) {
	make_ := func(callerBase string) (*station.Station, map[string]any) {
		st, err := station.New(&station.Options{
			NoConfig: true,
			Config: map[string]any{
				"station": 1,
				"profiles": map[string]any{
					"default": map[string]any{
						"sdk": map[string]any{
							"fakepad": map[string]any{"base": "http://profile:9"},
						},
					},
				},
			},
		})
		if nil != err {
			t.Fatal(err)
		}

		client := &fakeClient{mode: "live", fetcher: okResponse()}
		calleropts := map[string]any{}
		if "" != callerBase {
			calleropts["base"] = callerBase
		}
		options := map[string]any{"apikey": "", "base": "http://config:1",
			"feature": map[string]any{}}
		fopts := map[string]any{"active": true, "station": st, "calleropts": calleropts}
		options["feature"].(map[string]any)["station"] = fopts

		station.Bind(&station.BindSpec{
			Client: client, Config: fakeConfig("fakepad", "FakeSDK", true),
			SDKOptions: options, FeatureOpts: fopts,
			FeatureNames: []string{"station"},
			Mode:         func() string { return client.mode },
			Fetch:        client.fetcher,
			SetFetch:     func(next station.TransportFunc) { client.fetcher = next },
		})
		return st, options
	}

	// Caller set no base: the profile's per-plugin base wins over the
	// SDK config default (layer 4 over layer 1).
	_, options := make_("")
	if "http://profile:9" != options["base"] {
		t.Fatalf("profile base not applied: %v", options["base"])
	}

	// Caller opts (layer 7) beat the profile.
	_, options = make_("http://caller:7")
	if "http://config:1" != options["base"] {
		// options["base"] was already resolved by the SDK's makeOptions
		// from the caller's value before Init; Bind must NOT overwrite it.
		t.Fatalf("caller base overridden: %v", options["base"])
	}
}

// --- descriptor surface (design §3.2) ---

func TestDescriptorSurface(t *testing.T) {
	st := newStation(t, map[string]string{})
	bindOne(t, st, "fakepad", []string{"station"}, okResponse(), "")

	descriptor, err := st.DescriptorOf("fakepad")
	if nil != err {
		t.Fatal(err)
	}
	if "FAKEPAD" != descriptor["envtoken"] {
		t.Fatalf("envtoken: %v", descriptor["envtoken"])
	}

	canonical, err := st.CanonicalDescriptor("fakepad")
	if nil != err {
		t.Fatal(err)
	}
	if !strings.HasPrefix(canonical, "{\"auth\":") {
		t.Fatalf("canonical serialization must sort keys: %s", canonical[:24])
	}

	_, err = st.DescriptorOf("nope")
	serr, is := err.(*station.Error)
	if !is || "station_no_plugin" != serr.Code ||
		!strings.Contains(serr.Message, "fakepad") {
		t.Fatalf("unknown plugin must list candidates: %v", err)
	}

	plugins := st.Plugins()
	if 1 != len(plugins) || "R1" != plugins[0].Rung {
		t.Fatalf("plugins surface wrong: %+v", plugins)
	}
}
