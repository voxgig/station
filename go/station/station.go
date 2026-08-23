// The station library core, solo mode (design D1): fully functional
// in-process with no other component running. The proxy (D2) is a
// deferred amplifier - `require` therefore fails on the operation path
// (design §2.1/§14), and `auto` degrades to solo with one warning event.
//
// A port of typescript/src/Station.ts, which is canonical. Go's SDKs
// bind through the INVERTED form (design §3.1): the app constructs the
// generated SDK with station-built options -
//
//	st := station.Open(nil)
//	sdk := taskpad.NewTaskpadSDK(st.Options(nil))
//
// - and the generated station feature reads the handle from its feature
// options (or falls back to the ambient instance) and calls Bind.
package station

import (
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Options configure a Station (design §3.5 layer 6).
type Options struct {
	// Profile selects the station.json profile ('' = VOXGIG_STATION_PROFILE,
	// else 'default').
	Profile string
	// Proxy is 'auto' (default), 'off', 'require', or a URL. The proxy
	// itself is deferred; 'require' fails operations closed (§2.1).
	Proxy string
	// Folder starts the station.json walk somewhere other than the
	// working directory.
	Folder string
	// Config, when non-nil, is used instead of loading station.json.
	Config map[string]any
	// NoConfig true means no config at all: skip the disk lookup (the
	// explicit `config: null` of the canonical ts library).
	NoConfig bool
}

// PluginEntry is one registered plugin (design §3.2).
type PluginEntry struct {
	Slug       string
	Descriptor map[string]any
	Rung       string // 'none' | 'R1'
	Client     any
	Warnings   []string
}

// Status is the solo status surface (design §6).
type Status struct {
	Mode    string            `json:"mode"`
	Profile string            `json:"profile"`
	Plugins []PluginStatus    `json:"plugins"`
	Events  EventBufferStatus `json:"events"`
}

type PluginStatus struct {
	Slug string `json:"slug"`
	Rung string `json:"rung"`
}

// opState carries the per-operation correlation id from the PrePoint
// hook to the transport middleware and the PreDone/PreUnexpected hooks
// (design §3 item 3). Keyed by the SDK's own per-op context value.
type opState struct {
	corr  string
	start int64
}

type Station struct {
	mu             sync.Mutex
	opts           Options
	profile        *ResolvedProfile
	broker         *secretBroker
	buffer         *eventBuffer
	registry       map[string]*PluginEntry
	secretOverride map[string]string
	requireProxy   bool
	closed         bool
	ops            map[any]*opState
	lastSweep      int64
}

var (
	ambientMu   sync.Mutex
	ambient     *Station
	ambientOpts string
)

// Package-wide so correlation ids stay unique across instances, like the
// canonical library's module-level counter.
var corrMu sync.Mutex
var corrSeq int64

func nextCorr() string {
	corrMu.Lock()
	defer corrMu.Unlock()
	corrSeq++
	return "c" + strconv.FormatInt(corrSeq, 10)
}

func nowMs() int64 {
	return time.Now().UnixMilli()
}

func optsKey(opts *Options) string {
	if nil == opts {
		opts = &Options{}
	}
	return CanonicalSerialize(map[string]any{
		"profile":  opts.Profile,
		"proxy":    opts.Proxy,
		"folder":   opts.Folder,
		"config":   opts.Config,
		"noconfig": opts.NoConfig,
	})
}

// Open returns the process-ambient singleton (design §10.2): it is
// idempotent, and a second Open with conflicting options PANICS with
// station_open_conflict - construction-time misconfiguration, the same
// idiom the generated SDKs use for a broken base URL. Open is
// non-blocking - solo involves no network, and the deferred proxy probe
// must never change that. Use New for an isolated instance.
func Open(opts *Options) *Station {
	ambientMu.Lock()
	defer ambientMu.Unlock()

	key := optsKey(opts)
	if nil != ambient {
		if key != ambientOpts {
			panic(fail("station_open_conflict",
				"station.Open() was already called with different options"))
		}
		return ambient
	}

	st, err := New(opts)
	if nil != err {
		panic(err)
	}
	ambient = st
	ambientOpts = key
	return ambient
}

// Current is the ambient instance, or nil - never creates one. The
// generated station feature binds through this when no explicit handle
// rides its options (design §3.1: binding is never implicit; only Open()
// creates the ambient instance).
func Current() *Station {
	ambientMu.Lock()
	defer ambientMu.Unlock()
	return ambient
}

// Reset is the test seam: drop the ambient instance.
func Reset() {
	ambientMu.Lock()
	defer ambientMu.Unlock()
	ambient = nil
	ambientOpts = ""
}

// New creates an isolated Station for tests and multi-tenant hosts
// (design §10.2).
func New(opts *Options) (*Station, error) {
	if nil == opts {
		opts = &Options{}
	}

	config := opts.Config
	if nil == config && !opts.NoConfig {
		loaded, err := LoadConfig(opts.Folder)
		if nil != err {
			return nil, err
		}
		config = loaded
	}

	profile, err := ResolveProfile(config, SelectProfile(opts.Profile))
	if nil != err {
		return nil, err
	}

	broker, err := newSecretBroker(profile.Providers)
	if nil != err {
		return nil, err
	}

	proxy := opts.Proxy
	if "" == proxy {
		proxy = "auto"
	}

	st := &Station{
		opts:           *opts,
		profile:        profile,
		broker:         broker,
		buffer:         newEventBuffer(1000),
		registry:       map[string]*PluginEntry{},
		secretOverride: map[string]string{},
		requireProxy:   "require" == proxy,
		ops:            map[any]*opState{},
	}

	if "auto" == proxy {
		// The probe is deferred with the proxy itself; absence degrades
		// to solo with a single warning event naming the cause (§14).
		st.emit(Event{
			T: nowMs(), Kind: "station",
			Meta: map[string]any{"warn": "proxy absent (not found); running solo"},
		})
	}

	return st, nil
}

// --- the inverted binding form (design §3.1) ---

// Options builds the plain options map a generated constructor already
// accepts - the handle, the activation entry, and the caller's own opts
// (whose base, when set, wins over the profile's per-plugin base at bind
// time, design §3.5).
func (st *Station) Options(extra map[string]any) map[string]any {
	// calleropts snapshots what the CALLER passed - never the built
	// options map, which would make options.feature.station.calleropts
	// a cycle the SDK's own deep clone cannot survive.
	calleropts := map[string]any{}
	out := map[string]any{}
	for k, v := range extra {
		calleropts[k] = v
		out[k] = v
	}

	fmap := map[string]any{}
	for k, v := range asMap(out["feature"]) {
		fmap[k] = v
	}
	sopts := map[string]any{}
	for k, v := range asMap(fmap["station"]) {
		sopts[k] = v
	}
	sopts["active"] = true
	sopts["station"] = st
	sopts["calleropts"] = calleropts
	fmap["station"] = sopts
	out["feature"] = fmap

	return out
}

// --- registration (design §3 item 1, called by Bind) ---

// boundEntry is the registry entry whose client IS this value, or nil.
// Used by Bind for idempotency: a construction that reaches the binding
// twice for one client must no-op the second arrival, while a genuinely
// second client of the same SDK still fails register's slug check
// (§10.2).
func (st *Station) boundEntry(client any) *PluginEntry {
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, entry := range st.registry {
		if entry.Client == client {
			return entry
		}
	}
	return nil
}

type registration struct {
	entry         *PluginEntry
	placeholder   string
	profilePlugin map[string]any
}

func (st *Station) register(client any, config map[string]any,
	options map[string]any, fopts map[string]any) *registration {

	descriptor, warnings := NormalizeDescriptor(config, asMap(options["feature"]))
	slug := asString(descriptor["slug"])

	st.mu.Lock()
	if _, has := st.registry[slug]; has {
		st.mu.Unlock()
		panic(fail("station_bound_twice",
			"plugin \""+slug+"\" is already registered; binding one client "+
				"twice is an error (§10.2)"))
	}

	profilePlugin := st.profile.Sdk[slug]

	// Secret name precedence: the feature option (in-code, design §9
	// config.options.secret) beats the profile, which beats the
	// descriptor default.
	if secret := asString(fopts["secret"]); "" != secret {
		st.secretOverride[slug] = secret
	}

	auth := asMap(descriptor["auth"])
	authActive := true == auth["active"]
	rung := "none"
	if authActive {
		rung = "R1"
	}

	entry := &PluginEntry{
		Slug: slug, Descriptor: descriptor, Rung: rung,
		Client: client, Warnings: warnings,
	}
	st.registry[slug] = entry
	st.mu.Unlock()

	for _, warning := range warnings {
		st.emit(Event{T: nowMs(), Kind: "station", Plugin: slug,
			Meta: map[string]any{"warn": warning}})
	}
	st.emit(Event{
		T: nowMs(), Kind: "construct", Plugin: slug,
		Meta: map[string]any{
			"name":    descriptor["name"],
			"version": descriptor["version"],
			"rung":    rung,
		},
	})

	return &registration{
		entry:         entry,
		placeholder:   PlaceholderFor(slug),
		profilePlugin: profilePlugin,
	}
}

func (st *Station) hoist(slug string, value string) {
	st.broker.hoist(slug, value)
	st.emit(Event{
		T: nowMs(), Kind: "station", Plugin: slug,
		Meta: map[string]any{
			"warn": "a resident credential was hoisted into the broker and " +
				"replaced by the placeholder; prefer configuring the secret " +
				"name and letting sekreto resolve it",
		},
	})
}

// --- the transport middleware (design §3.3, §5.3) ---

func (st *Station) transport(entry *PluginEntry, mode func() string,
	inner TransportFunc, opctx any, fullurl string,
	fetchdef map[string]any) (any, error) {

	slug := entry.Slug

	// Fail-closed means traffic (§2.1): with the proxy deferred,
	// `require` can never attach, so every operation fails here - the
	// operation path, never the constructor.
	if st.requireProxy {
		err := fail("station_no_proxy",
			"proxy: \"require\" is set and no proxy is attached")
		st.emitErr(slug, opctx, err)
		return nil, err
	}

	placeholder := PlaceholderFor(slug)
	live := "live" == mode()

	st.mu.Lock()
	profilePlugin := st.profile.Sdk[slug]
	override := st.secretOverride[slug]
	st.mu.Unlock()

	// Egress policy (design §16), solo half: the hosts allowlist is
	// enforced at the seam every request crosses. When a policy is
	// present, redirects come back manual - a 3xx is a response like
	// any other, so a Location off the allowlist cannot pull an
	// automatic credentialed follow-up to an unapproved host (§8.2's
	// rule, applied at the library seam).
	hosts, hasHosts := hostsPolicy(profilePlugin)
	if hasHosts && live {
		hostname := ""
		if u, err := url.Parse(fullurl); nil == err {
			hostname = u.Hostname()
		}
		allowed := false
		for _, host := range hosts {
			if host == hostname {
				allowed = true
				break
			}
		}
		if !allowed {
			err := fail("station_host_allow",
				"egress to \""+hostname+"\" denied by the hosts policy of "+
					"plugin \""+slug+"\"")
			st.emitErr(slug, opctx, err)
			return nil, err
		}
	}

	senddef := fetchdef
	if hasHosts && live {
		senddef = cloneFetchdef(senddef, false)
		senddef["redirect"] = "manual"
	}

	// Injection: at the last boundary, below every recording feature,
	// and never into mock transports (§3.3) - in test/mock modes the
	// placeholder rides through untouched, so real credentials never
	// enter in-memory mock stores. Copy-on-inject: the object graph
	// reachable from ctx/spec/ctrl keeps the placeholder, ever (§5.3).
	if live && "R1" == entry.Rung {
		secretname := override
		if "" == secretname {
			secretname = asString(profilePlugin["secret"])
		}
		if "" == secretname {
			secretname = asString(asMap(entry.Descriptor["auth"])["secretname"])
		}

		value, err := st.broker.value(slug, secretname)
		if nil != err {
			st.emitErr(slug, opctx, err)
			return nil, err
		}

		senddef = cloneFetchdef(senddef, true)
		headers := asMap(senddef["headers"])
		for name, raw := range headers {
			if text, is := raw.(string); is && strings.Contains(text, placeholder) {
				headers[name] = strings.ReplaceAll(text, placeholder, value)
			}
		}
	}

	corr := st.corrOf(opctx)
	started := nowMs()

	res, err := inner(opctx, fullurl, senddef)
	if nil != err {
		st.emitHTTP(slug, corr, fullurl, senddef, 0, started, 0)
		st.emitErr(slug, opctx, err)
		return res, err
	}

	status := 0
	var bytes int64
	if rm, is := res.(map[string]any); is {
		status = toInt(rm["status"])
		if cl, has := asMap(rm["headers"])["content-length"]; has {
			bytes = int64(toInt(cl))
		}
	}
	st.emitHTTP(slug, corr, fullurl, senddef, status, started, bytes)

	return res, nil
}

// cloneFetchdef copies the fetchdef map, and its headers map when
// withHeaders - the generated request machinery shares references
// (fetchdef.headers IS spec.headers, and ctrl.explain stores fetchdef by
// reference before the fetcher runs), so an in-place swap would leak the
// real value into ctx/spec/ctrl (design §5.3 copy-on-inject).
func cloneFetchdef(fetchdef map[string]any, withHeaders bool) map[string]any {
	out := map[string]any{}
	for k, v := range fetchdef {
		out[k] = v
	}
	if withHeaders {
		headers := map[string]any{}
		for k, v := range asMap(out["headers"]) {
			headers[k] = v
		}
		out["headers"] = headers
	}
	return out
}

func hostsPolicy(profilePlugin map[string]any) ([]string, bool) {
	policy := asMap(profilePlugin["policy"])
	raw, has := policy["hosts"]
	if !has || nil == raw {
		return nil, false
	}
	out := []string{}
	if list, is := raw.([]any); is {
		for _, one := range list {
			if s, is := one.(string); is {
				out = append(out, s)
			}
		}
		return out, true
	}
	if list, is := raw.([]string); is {
		return list, true
	}
	return nil, false
}

func (st *Station) emitHTTP(slug string, corr string, fullurl string,
	fetchdef map[string]any, status int, started int64, bytes int64) {

	host, path := "", ""
	if u, err := url.Parse(fullurl); nil == err {
		host = u.Host
		path = u.Path
	} else {
		path = fullurl
	}
	method := asString(fetchdef["method"])
	if "" == method {
		method = "GET"
	}
	st.emit(Event{
		T: started, Kind: "http", Plugin: slug, Corr: corr,
		HTTP: &HTTPEvent{
			Method: method, Host: host, Path: path, Status: status,
			DurationMs: nowMs() - started, Bytes: bytes,
		},
	})
}

func (st *Station) emitErr(slug string, opctx any, err error) {
	code := ""
	if serr, is := err.(*Error); is {
		code = serr.Code
	}
	message := ""
	if nil != err {
		message = err.Error()
	}
	st.emit(Event{
		T: nowMs(), Kind: "error", Plugin: slug, Corr: st.corrOf(opctx),
		Err: &ErrEvent{
			Code: code,
			// The scrub keeps an upstream echo of a credential out of the
			// event stream (§7 as revised: exact-value, no length floor).
			Message: st.Redact(message),
		},
	})
}

// --- the per-op correlation store (design §3 item 3) ---

// The canonical library hangs {corr, start} on the SDK's own per-op ctx
// object. A Go struct takes no ad-hoc fields, so the state is keyed by
// the op context value in a station-held map, swept periodically in case
// an op path dies without reaching PreDone or PreUnexpected.
func (st *Station) opStart(opctx any) {
	if nil == opctx {
		return
	}
	now := nowMs()
	st.mu.Lock()
	defer st.mu.Unlock()
	st.sweepOpsLocked(now)
	st.ops[opctx] = &opState{corr: nextCorr(), start: now}
}

func (st *Station) corrOf(opctx any) string {
	if nil == opctx {
		return ""
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if state, has := st.ops[opctx]; has {
		return state.corr
	}
	return ""
}

func (st *Station) opEnd(opctx any) (string, int64) {
	if nil == opctx {
		return "", 0
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if state, has := st.ops[opctx]; has {
		delete(st.ops, opctx)
		return state.corr, state.start
	}
	return "", 0
}

func (st *Station) sweepOpsLocked(now int64) {
	if 4096 > len(st.ops) || now-st.lastSweep < 60_000 {
		return
	}
	st.lastSweep = now
	for key, state := range st.ops {
		if now-state.start > 300_000 {
			delete(st.ops, key)
		}
	}
}

// opEvent is the op-kind event from the hook bridge (design §3 item 3).
func (st *Station) opEvent(slug string, opctx any, info OpInfo, outcome string) {
	corr, start := st.opEnd(opctx)
	duration := int64(0)
	if 0 != start {
		duration = nowMs() - start
	}
	st.emit(Event{
		T: nowMs(), Kind: "op", Plugin: slug, Corr: corr,
		Op: &OpEvent{
			Entity: info.Entity, Op: info.Op,
			Outcome: outcome, DurationMs: duration,
		},
	})
}

// --- the query/observe surface (design §3.2, §6) ---

// Plugins lists the registered plugins: descriptor, rung, warnings.
func (st *Station) Plugins() []PluginEntry {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := make([]PluginEntry, 0, len(st.registry))
	slugs := make([]string, 0, len(st.registry))
	for slug := range st.registry {
		slugs = append(slugs, slug)
	}
	sort.Strings(slugs)
	for _, slug := range slugs {
		entry := st.registry[slug]
		warnings := make([]string, len(entry.Warnings))
		copy(warnings, entry.Warnings)
		out = append(out, PluginEntry{
			Slug: entry.Slug, Descriptor: entry.Descriptor,
			Rung: entry.Rung, Client: entry.Client, Warnings: warnings,
		})
	}
	return out
}

// DescriptorOf returns a plugin's descriptor, or an error naming the
// known plugins (design §7's affordance, applied at the library seam).
func (st *Station) DescriptorOf(slug string) (map[string]any, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	entry, has := st.registry[slug]
	if !has {
		known := make([]string, 0, len(st.registry))
		for one := range st.registry {
			known = append(known, one)
		}
		sort.Strings(known)
		return nil, fail("station_no_plugin", "unknown plugin \""+slug+
			"\"; known: ["+strings.Join(known, ", ")+"]")
	}
	return entry.Descriptor, nil
}

// CanonicalDescriptor is the §4 canonical serialization of a plugin's
// descriptor.
func (st *Station) CanonicalDescriptor(slug string) (string, error) {
	descriptor, err := st.DescriptorOf(slug)
	if nil != err {
		return "", err
	}
	return CanonicalSerialize(descriptor), nil
}

// Events returns a copy of the ring buffer.
func (st *Station) Events() []Event {
	return st.buffer.events()
}

// Tap subscribes to the live event stream; the returned func
// unsubscribes. Callbacks are serialized and a panicking tap never fails
// an operation (design §6).
func (st *Station) Tap(fn func(Event)) func() {
	return st.buffer.tap(fn)
}

// StationStatus is the solo status surface (design §6).
func (st *Station) Status() Status {
	st.mu.Lock()
	plugins := make([]PluginStatus, 0, len(st.registry))
	slugs := make([]string, 0, len(st.registry))
	for slug := range st.registry {
		slugs = append(slugs, slug)
	}
	sort.Strings(slugs)
	for _, slug := range slugs {
		plugins = append(plugins, PluginStatus{Slug: slug, Rung: st.registry[slug].Rung})
	}
	name := st.profile.Name
	st.mu.Unlock()

	return Status{
		Mode:    "solo",
		Profile: name,
		Plugins: plugins,
		Events:  st.buffer.status(),
	}
}

// Redact scrubs every credential this station has held from the text -
// exact values, no length floor (design §7 as revised).
func (st *Station) Redact(text string) string {
	return st.broker.scrub(text)
}

// RefreshSecrets drops the resolved-value caches so the next injection
// asks the stores again (design §5.3 rotation).
func (st *Station) RefreshSecrets() {
	st.broker.refresh()
}

// Close flushes (solo: nothing in flight), then warns on profile plugin
// keys that matched no registered plugin - a typo'd key silently
// configuring nothing is the worst outcome for a secrets-and-policy
// file (design §11). Idempotent.
func (st *Station) Close() {
	st.mu.Lock()
	if st.closed {
		st.mu.Unlock()
		return
	}
	unmatched := []string{}
	for slug := range st.profile.Sdk {
		if _, has := st.registry[slug]; !has {
			unmatched = append(unmatched, slug)
		}
	}
	sort.Strings(unmatched)
	st.closed = true
	st.mu.Unlock()

	for _, slug := range unmatched {
		st.emit(Event{
			T: nowMs(), Kind: "station",
			Meta: map[string]any{
				"warn": "profile plugin key \"" + slug +
					"\" matched no registered plugin",
			},
		})
	}

	ambientMu.Lock()
	if ambient == st {
		ambient = nil
		ambientOpts = ""
	}
	ambientMu.Unlock()
}

func (st *Station) emit(event Event) {
	st.buffer.emit(event)
}

func toInt(val any) int {
	switch n := val.(type) {
	case int:
		return n
	case int64:
		return int(n)
	case float64:
		return int(n)
	case float32:
		return int(n)
	case string:
		if parsed, err := strconv.Atoi(n); nil == err {
			return parsed
		}
	}
	return 0
}
