package station

import (
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Options struct {
	// Profile selects the station.json profile ('' = VOXGIG_STATION_PROFILE,
	// else 'default').
	Profile string
	// Proxy is 'auto' (default), 'off', 'require', or a URL. The proxy
	// itself is deferred; 'require' fails operations closed (§2.1).
	Proxy  string
	Folder string
	// Config, when non-nil, is used instead of loading station.json.
	Config map[string]any
	// NoConfig true means no config at all: skip the disk lookup (the
	// explicit `config: null` of the canonical ts library).
	NoConfig   bool
	RepoScoped *bool
	// Load is ACCEPTED AND INERT here (§6.3, §5.4 item 4): this port has
	// no loader to switch off. The field exists so one config and one
	// call site serve a polyglot fleet.
	Load *bool
}

type PluginEntry struct {
	Name string
	API  string
	// Slug is retained and equals API: it is what `slug` always meant
	// here, and the two are the same string for an untagged instance.
	Slug       string
	Descriptor map[string]any
	Rung       string
	// Secretname is the EFFECTIVE name, resolved once at registration
	// (§7.4). The transport seam reads it from here with no fallback.
	Secretname string
	Client     any
	Warnings   []string
}

// Instance is one DECLARED instance (design §6.1) - a different question
// from Plugins(), and the answers differ routinely: a lazily-started
// instance is Active and not yet Live.
type Instance struct {
	Name   string         `json:"name"`
	API    string         `json:"api"`
	Active bool           `json:"active"`
	Live   bool           `json:"live"`
	Rung   string         `json:"rung"`
	Block  map[string]any `json:"block"`
}

// FeatureSet is the merged, ordered feature set for one instance, with
// per-value provenance (design §8.7).
type FeatureSet struct {
	Ordered  []string                     `json:"ordered"`
	Merged   map[string]any               `json:"merged"`
	From     map[string]map[string]string `json:"from"`
	Declared []string                     `json:"declared"`
}

type FeatureRow struct {
	Instance string                       `json:"instance"`
	API      string                       `json:"api"`
	Ordered  []string                     `json:"ordered"`
	Merged   map[string]any               `json:"merged"`
	From     map[string]map[string]string `json:"from"`
}

type FeatureFilter struct {
	Instance string
	API      string
	Feature  string
	// Loose matches an instance name OR an api, which is what the string
	// shorthand means.
	Loose bool
}

func LooseFilter(text string) *FeatureFilter {
	return &FeatureFilter{Instance: text, API: text, Loose: true}
}

type CheckFailure struct {
	Name    string `json:"name"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type CheckResult struct {
	OK     []string       `json:"ok"`
	Failed []CheckFailure `json:"failed"`
}

type WarmResult struct {
	Warmed []string `json:"warmed"`
	Missed []string `json:"missed"`
}

type Status struct {
	Mode    string            `json:"mode"`
	Profile string            `json:"profile"`
	Plugins []PluginStatus    `json:"plugins"`
	Events  EventBufferStatus `json:"events"`
}

type PluginStatus struct {
	Name string `json:"name"`
	API  string `json:"api"`
	Slug string `json:"slug"`
	Rung string `json:"rung"`
}

type describedSDK struct {
	descriptor map[string]any
	warnings   []string
}

// opState carries the per-operation correlation id from the PrePoint
// hook to the transport middleware and the PreDone/PreUnexpected hooks
// (design §3 item 3). Keyed by the SDK's own per-op context value.
type opState struct {
	corr  string
	start int64
}

type Station struct {
	mu      sync.Mutex
	opts    Options
	profile *ResolvedProfile
	// raw is the config as written, kept for §8.7's provenance: the
	// resolved profile has already collapsed the levels provenance has
	// to name.
	raw map[string]any
	// raworder is raw's key declaration order (order.go). nil for a
	// config passed in code, which has none.
	raworder   *Order
	repoScoped bool
	broker     *secretBroker
	buffer     *eventBuffer
	registry   map[string]*PluginEntry
	clients    map[string]any
	// aliasOf maps an auto-assigned tag to the DECLARED instance it
	// stands for (§5.3). Beside the registry rather than inside it,
	// because the mapping exists before construction and BlockFor needs
	// it during registration.
	aliasOf         map[string]string
	descriptorCache map[string]*describedSDK
	requireProxy    bool
	closed          bool
	ops             map[any]*opState
	lastSweep       int64
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
	key := map[string]any{
		"profile":  opts.Profile,
		"proxy":    opts.Proxy,
		"folder":   opts.Folder,
		"config":   opts.Config,
		"noconfig": opts.NoConfig,
	}
	if nil != opts.RepoScoped {
		key["reposcoped"] = *opts.RepoScoped
	}
	if nil != opts.Load {
		key["load"] = *opts.Load
	}
	return CanonicalSerialize(key)
}

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

func Reset() {
	ambientMu.Lock()
	defer ambientMu.Unlock()
	ambient = nil
	ambientOpts = ""
}

func New(opts *Options) (*Station, error) {
	if nil == opts {
		opts = &Options{}
	}

	incode := nil != opts.Config
	config := opts.Config
	var raworder *Order
	if !incode && !opts.NoConfig {
		loaded, order, err := LoadConfigOrder(opts.Folder)
		if nil != err {
			return nil, err
		}
		config, raworder = loaded, order
	}

	repoScoped := false
	if nil != opts.RepoScoped {
		repoScoped = *opts.RepoScoped
	} else if incode || opts.NoConfig {
		// NoConfig is the canonical library's explicit `config: null`,
		// which takes the same branch: the application settled the
		// question in code, so there is no file whose location could
		// answer it.
		repoScoped = true
	} else {
		repoScoped = "user" != ConfigScope(opts.Folder)
	}

	if nil != config {
		if _, err := ValidateConfig(NormalizeConfig(config)); nil != err {
			return nil, err
		}
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
		opts:            *opts,
		profile:         profile,
		raw:             config,
		raworder:        raworder,
		repoScoped:      repoScoped,
		broker:          broker,
		buffer:          newEventBuffer(1000),
		registry:        map[string]*PluginEntry{},
		clients:         map[string]any{},
		aliasOf:         map[string]string{},
		descriptorCache: map[string]*describedSDK{},
		requireProxy:    "require" == proxy,
		ops:             map[any]*opState{},
	}

	if "auto" == proxy {
		// The probe is deferred with the proxy itself; absence degrades
		// to solo with a single warning event naming the cause (§14).
		st.emit(Event{
			T: nowMs(), Kind: "station",
			Meta: map[string]any{"warn": "proxy absent (not found); running solo"},
		})
	}

	// §5.4 item 2: `package` stays in the grammar - one config file
	// serves a polyglot fleet - and is IGNORED HERE, with a warning
	// event at open rather than an error. One event per api, once.
	st.warnPackages()

	return st, nil
}

func (st *Station) RepoScoped() bool {
	return st.repoScoped
}

// Options builds the plain options map a generated constructor already
// accepts - the handle, the activation entry, and the caller's own opts
// (whose base, when set, wins over the profile's per-instance base at
// bind time, design §3.5).
func (st *Station) Options(extra map[string]any) map[string]any {
	return st.OptionsFor("", extra)
}

// OptionsFor is Options with the INSTANCE NAME the construction
// registers under (§6.1). Go cannot overload on a leading optional
// argument the way the canonical `options(instanceName?, extra?)` does,
// so the name gets its own method and every existing Options({...}) call
// is unchanged.
func (st *Station) OptionsFor(instance string, extra map[string]any) map[string]any {
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
	if "" != instance {
		sopts["instance"] = instance
	}
	fmap["station"] = sopts
	out["feature"] = fmap

	return out
}

// boundEntry is the registry entry whose client IS this value, or nil.
// Used by Bind for idempotency: a construction that reaches the binding
// twice for one client must no-op the second arrival, while a genuinely
// second client of the same INSTANCE still fails register's name check
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
	entry       *PluginEntry
	placeholder string
	block       map[string]any
}

func (st *Station) BlockFor(name string) map[string]any {
	declared := st.DeclaredRef(name)
	st.mu.Lock()
	defer st.mu.Unlock()
	if block, has := st.profile.Sdk[declared]; has {
		return block
	}
	return st.profile.Api[RefApi(name)]
}

func (st *Station) DeclaredRef(name string) string {
	st.mu.Lock()
	defer st.mu.Unlock()
	if declared, has := st.aliasOf[name]; has {
		return declared
	}
	return name
}

func (st *Station) register(client any, config map[string]any,
	options map[string]any, fopts map[string]any) *registration {

	descriptor, warnings := st.describe(config)
	api := asString(descriptor["slug"])

	// §7.5: station knows the instance name before construction begins
	// and passes it through the feature options. A bare build with no
	// name falls back to the api slug, which is today's behaviour and
	// why the single-instance case is unchanged.
	name, err := InstanceRef(api, fopts)
	if nil != err {
		panic(err)
	}

	block := st.BlockFor(name)

	secretname := asString(fopts["secret"])
	if "" == secretname {
		secretname = asString(block["secret"])
	}
	if "" == secretname {
		secretname = SecretnameDefault(st.DeclaredRef(name))
	}

	auth := asMap(descriptor["auth"])
	authActive := true == auth["active"]
	rung := "none"
	if authActive {
		rung = "R1"
	}
	if !authActive {
		secretname = ""
	}

	st.mu.Lock()
	if _, has := st.registry[name]; has {
		st.mu.Unlock()
		panic(fail("station_bound_twice",
			"instance \""+name+"\" is already registered; binding one client "+
				"twice is an error (§10.2)"))
	}

	entry := &PluginEntry{
		Name: name, API: api, Slug: api, Descriptor: descriptor, Rung: rung,
		Secretname: secretname, Client: client, Warnings: warnings,
	}
	st.registry[name] = entry
	st.mu.Unlock()

	for _, warning := range warnings {
		st.emit(Event{T: nowMs(), Kind: "station", Plugin: name, API: api,
			Meta: map[string]any{"warn": warning}})
	}
	st.emit(Event{
		T: nowMs(), Kind: "construct", Plugin: name, API: api,
		Meta: map[string]any{
			"name":    descriptor["name"],
			"version": descriptor["version"],
			"rung":    rung,
		},
	})

	return &registration{
		entry:       entry,
		placeholder: PlaceholderFor(name),
		block:       block,
	}
}

func (st *Station) describe(config map[string]any) (map[string]any, []string) {
	slug := asString(asMap(config["main"])["slug"])

	st.mu.Lock()
	if "" != slug {
		if hit, has := st.descriptorCache[slug]; has {
			st.mu.Unlock()
			return hit.descriptor, hit.warnings
		}
	}
	st.mu.Unlock()

	descriptor, warnings := NormalizeDescriptor(config, nil)

	st.mu.Lock()
	defer st.mu.Unlock()
	st.descriptorCache[asString(descriptor["slug"])] = &describedSDK{
		descriptor: descriptor, warnings: warnings,
	}
	return descriptor, warnings
}

func (st *Station) hoist(name string, value string) {
	st.broker.hoist(name, value)
	st.emit(Event{
		T: nowMs(), Kind: "station", Plugin: name, API: RefApi(name),
		Meta: map[string]any{
			"warn": "a resident credential was hoisted into the broker and " +
				"replaced by the placeholder; prefer configuring the secret " +
				"name and letting sekreto resolve it",
		},
	})
}

func (st *Station) transport(entry *PluginEntry, mode func() string,
	inner TransportFunc, opctx any, fullurl string,
	fetchdef map[string]any) (any, error) {

	name := entry.Name

	// Fail-closed means traffic (§2.1): with the proxy deferred,
	// `require` can never attach, so every operation fails here - the
	// operation path, never the constructor.
	if st.requireProxy {
		err := fail("station_no_proxy",
			"proxy: \"require\" is set and no proxy is attached")
		st.emitErr(name, opctx, err)
		return nil, err
	}

	placeholder := PlaceholderFor(name)
	live := "live" == mode()

	block := st.BlockFor(name)

	hosts, hasHosts := hostsPolicy(block)
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
					"plugin \""+name+"\"")
			st.emitErr(name, opctx, err)
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
		value, err := st.broker.value(name, entry.Secretname)
		if nil != err {
			st.emitErr(name, opctx, err)
			return nil, err
		}

		senddef = cloneFetchdef(senddef, true)
		headers := asMap(senddef["headers"])
		for header, raw := range headers {
			if text, is := raw.(string); is && strings.Contains(text, placeholder) {
				headers[header] = strings.ReplaceAll(text, placeholder, value)
			}
		}
	}

	corr := st.corrOf(opctx)
	started := nowMs()

	res, err := inner(opctx, fullurl, senddef)
	if nil != err {
		st.emitHTTP(name, corr, fullurl, senddef, 0, started, 0)
		st.emitErr(name, opctx, err)
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
	st.emitHTTP(name, corr, fullurl, senddef, status, started, bytes)

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

func hostsPolicy(block map[string]any) ([]string, bool) {
	policy := asMap(block["policy"])
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

func (st *Station) emitHTTP(name string, corr string, fullurl string,
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
		T: started, Kind: "http", Plugin: name, API: RefApi(name), Corr: corr,
		HTTP: &HTTPEvent{
			Method: method, Host: host, Path: path, Status: status,
			DurationMs: nowMs() - started, Bytes: bytes,
		},
	})
}

func (st *Station) emitErr(name string, opctx any, err error) {
	code := ""
	if serr, is := err.(*Error); is {
		code = serr.Code
	}
	message := ""
	if nil != err {
		message = err.Error()
	}
	// §7.3's grouping contract: `plugin` is the INSTANCE and `api` is
	// what groups its siblings. Construction events carrying both while
	// runtime events carried only one is grouping that works exactly
	// until it is used.
	st.emit(Event{
		T: nowMs(), Kind: "error", Plugin: name, API: RefApi(name),
		Corr: st.corrOf(opctx),
		Err: &ErrEvent{
			Code: code,
			// The scrub keeps an upstream echo of a credential out of the
			// event stream (§7 as revised: exact-value, no length floor).
			Message: st.Redact(message),
		},
	})
}

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

func (st *Station) opEvent(name string, opctx any, info OpInfo, outcome string) {
	corr, start := st.opEnd(opctx)
	duration := int64(0)
	if 0 != start {
		duration = nowMs() - start
	}
	st.emit(Event{
		T: nowMs(), Kind: "op", Plugin: name, API: RefApi(name), Corr: corr,
		Op: &OpEvent{
			Entity: info.Entity, Op: info.Op,
			Outcome: outcome, DurationMs: duration,
		},
	})
}

// SDK returns the instance, constructed on first call and CACHED: same
// name -> same client. That caching is what makes "get it where you need
// it" a real instruction - call it in a request handler, in a worker, in
// a test, and the first call pays construction while the rest are a map
// lookup.
func (st *Station) SDK(name string) (any, error) {
	st.mu.Lock()
	cached, has := st.clients[name]
	st.mu.Unlock()
	if has {
		return cached, nil
	}

	client, err := st.Build(name, "", nil)
	if nil != err {
		return nil, err
	}

	st.mu.Lock()
	st.clients[name] = client
	st.mu.Unlock()
	return client, nil
}

func (st *Station) Create(name string, overrides map[string]any) (any, error) {
	return st.Build(name, st.Autotag(name), overrides)
}

func (st *Station) Autotag(name string) string {
	api := RefApi(name)
	st.mu.Lock()
	defer st.mu.Unlock()
	for n := 1; ; n++ {
		ref := api + "$" + strconv.Itoa(n)
		_, live := st.registry[ref]
		_, declared := st.profile.Sdk[ref]
		if !live && !declared {
			return ref
		}
	}
}

// Build is the shared construction path behind SDK and Create. `as` is
// the ASSIGNED tag, or "" when the instance is built under its own name.
func (st *Station) Build(name string, as string, overrides map[string]any) (
	any, error) {

	st.mu.Lock()
	closed := st.closed
	block, declared := st.profile.Sdk[name]
	refs := make([]string, 0, len(st.profile.Sdk))
	for ref := range st.profile.Sdk {
		refs = append(refs, ref)
	}
	st.mu.Unlock()

	if closed {
		return nil, fail("station_no_plugin", "station is closed")
	}
	if !declared {
		sort.Strings(refs)
		return nil, fail("station_no_instance",
			"no declared instance \""+name+"\"; declared: ["+
				strings.Join(refs, ", ")+"]")
	}
	if false == block["active"] {
		return nil, fail("station_instance_inactive",
			"instance \""+name+"\" is declared with `active: false`, which "+
				"bars it from running while keeping it visible in Instances()")
	}

	api := RefApi(name)
	entry, err := st.ResolveFactory(api, block)
	if nil != err {
		return nil, err
	}

	resolved, err := st.FeaturesOf(name)
	if nil != err {
		return nil, err
	}

	if faults := CheckFeatures(resolved.Merged, entry.Descriptor); 0 < len(faults) {
		return nil, fail(faults[0].Code, FaultMessages(faults))
	}

	rows, err := ResolveOrder(resolved.Merged, resolved.Declared)
	if nil != err {
		return nil, err
	}
	kept := make([]OrderedFeature, 0, len(rows))
	for _, row := range rows {
		if "station" != row.Name {
			kept = append(kept, row)
		}
	}
	fmap := map[string]any{}
	for _, one := range ComposeFeatures(kept) {
		fname := asString(one["name"])
		rest := map[string]any{}
		for k, v := range one {
			if "name" != k {
				rest[k] = v
			}
		}
		fmap[fname] = rest
	}

	opts := map[string]any{}
	for k, v := range asMap(block["options"]) {
		opts[k] = v
	}
	if base := asString(block["base"]); "" != base {
		opts["base"] = base
	}
	for k, v := range overrides {
		opts[k] = v
	}
	for k, v := range asMap(overrides["feature"]) {
		fmap[k] = v
	}
	opts["feature"] = fmap

	registerAs := name
	if "" != as && as != name {
		st.mu.Lock()
		st.aliasOf[as] = name
		st.mu.Unlock()
		registerAs = as
	}

	return entry.Construct(st.OptionsFor(registerAs, opts)), nil
}

func (st *Station) ResolveFactory(api string, block map[string]any) (
	*FactoryEntry, error) {

	if direct := FactoryFor(api); nil != direct {
		return direct, nil
	}

	return nil, fail("station_no_factory",
		"no factory for api \""+api+"\"; either blank-import a generated "+
			"package that self-registers in its func init(), or call "+
			"station.Provide(\""+api+"\", ...). `package` is not honoured in "+
			"the Go port: Go links its dependencies, so there is no "+
			"import-by-name at run time (§6.3)")
}

func (st *Station) LoaderPackage(api string, block map[string]any) string {
	return ""
}

// Load is present and INERT (§5.4 item 4): the preload exists so one
// startup sequence serves a polyglot fleet. Options{Load: &no} is
// accepted and equally inert.
func (st *Station) Load() error {
	return nil
}

// warnPackages emits one warning event per api whose declared block
// carries a non-empty `package`, at open, once.
func (st *Station) warnPackages() {
	seen := map[string]bool{}
	blocks := map[string]map[string]any{}
	for ref, block := range st.profile.Sdk {
		blocks[ref] = block
	}
	for slug, block := range st.profile.Api {
		if _, has := blocks[slug]; !has {
			blocks[slug] = block
		}
	}

	refs := make([]string, 0, len(blocks))
	for ref := range blocks {
		refs = append(refs, ref)
	}
	sort.Strings(refs)

	for _, ref := range refs {
		if "" == asString(blocks[ref]["package"]) {
			continue
		}
		api := RefApi(ref)
		if seen[api] {
			continue
		}
		seen[api] = true
		st.emit(Event{
			T: nowMs(), Kind: "station", Plugin: api, API: api,
			Meta: map[string]any{
				"warn": "`package` is not honoured in the Go port: Go links " +
					"its dependencies, so there is no import-by-name at run " +
					"time. api \"" + api + "\" must arrive by self-registration " +
					"(a blank import of the generated package) or " +
					"station.Provide (§6.3); everything else in this config " +
					"still applies",
			},
		})
	}
}

func (st *Station) FeaturesOf(name string) (*FeatureSet, error) {
	api := RefApi(name)

	st.mu.Lock()
	profiles := asMap(st.raw["profiles"])
	profileName := st.profile.Name
	raworder := st.raworder
	st.mu.Unlock()

	base := asMap(profiles["default"])
	overlay := map[string]any{}
	if "default" != profileName {
		overlay = asMap(profiles[profileName])
	}

	levels := []string{
		"default.feature", "default.api", "default.sdk",
		profileName + ".feature", profileName + ".api", profileName + ".sdk",
	}
	sources := FeatureSources(base, overlay, api, name)

	orders := make([][]string, len(sources))
	paths := FeatureSourcePaths("default", profileName, api, name)
	for i, path := range paths {
		orders[i] = raworder.At(path...).Keys()
	}

	// Last writer per (feature, key) wins, and the level that wrote it
	// is what From records.
	from := map[string]map[string]string{}
	for i, src := range sources {
		if nil == src {
			continue
		}
		for _, fname := range namesInOrder(src, orders[i]) {
			entry, is := src[fname].(map[string]any)
			if !is {
				continue
			}
			if nil == from[fname] {
				from[fname] = map[string]string{}
			}
			for _, k := range sortedKeys(entry) {
				from[fname][k] = levels[i]
			}
		}
	}

	merged := MergeFeatures(sources)
	declared := MergeFeatureOrder(sources, orders)

	if budget, is := asMap(st.BlockFor(name)["policy"])["budget"].(map[string]any); is {
		entry := map[string]any{}
		for k, v := range asMap(merged["ratelimit"]) {
			entry[k] = v
		}
		entry["active"] = true
		if nil == from["ratelimit"] {
			from["ratelimit"] = map[string]string{}
		}
		from["ratelimit"]["active"] = "policy.budget"
		if rps, has := budget["rps"]; has && nil != rps {
			entry["rate"] = rps
			from["ratelimit"]["rate"] = "policy.budget"
		}
		if concurrency, has := budget["concurrency"]; has && nil != concurrency {
			entry["burst"] = concurrency
			from["ratelimit"]["burst"] = "policy.budget"
		}
		if _, had := merged["ratelimit"]; !had {
			declared = append(declared, "ratelimit")
		}
		merged["ratelimit"] = entry
	}

	withStation := map[string]any{}
	for k, v := range merged {
		withStation[k] = v
	}
	withStation["station"] = map[string]any{"active": true}

	ordered, err := ResolveOrder(withStation, append(append([]string{},
		declared...), "station"))
	if nil != err {
		return nil, err
	}
	if err := CheckPin(ordered); nil != err {
		return nil, err
	}

	return &FeatureSet{
		Ordered: FeatureNames(ordered), Merged: merged, From: from,
		Declared: declared,
	}, nil
}

// Features is the fleet feature view: instance x feature, effective
// options, and which config level set each (§8.7). A nil filter is
// everything; LooseFilter(text) is the string shorthand.
func (st *Station) Features(filter *FeatureFilter) ([]FeatureRow, error) {
	f := filter
	if nil == f {
		f = &FeatureFilter{}
	}

	rows := []FeatureRow{}
	for _, one := range st.Instances() {
		if f.Loose {
			if "" != f.Instance && one.Name != f.Instance && one.API != f.API {
				continue
			}
		} else {
			if "" != f.Instance && one.Name != f.Instance && one.API != f.Instance {
				continue
			}
			if "" != f.API && one.API != f.API {
				continue
			}
		}

		resolved, err := st.FeaturesOf(one.Name)
		if nil != err {
			return nil, err
		}
		rows = append(rows, FeatureRow{
			Instance: one.Name, API: one.API, Ordered: resolved.Ordered,
			Merged: resolved.Merged, From: resolved.From,
		})
	}

	// `feature` filters the ROWS, not the instances: an instance that
	// does not carry the named feature is not part of the answer, and
	// the rows that remain are narrowed to it, so the view answers
	// "where is debug on, and with what" rather than "here is
	// everything, go and look".
	if "" == f.Feature {
		return rows, nil
	}
	narrowed := []FeatureRow{}
	for _, row := range rows {
		entry, has := row.Merged[f.Feature]
		if !has {
			continue
		}
		ordered := []string{}
		for _, n := range row.Ordered {
			if n == f.Feature {
				ordered = append(ordered, n)
			}
		}
		fromone := map[string]string{}
		for k, v := range row.From[f.Feature] {
			fromone[k] = v
		}
		narrowed = append(narrowed, FeatureRow{
			Instance: row.Instance, API: row.API, Ordered: ordered,
			Merged: map[string]any{f.Feature: entry},
			From:   map[string]map[string]string{f.Feature: fromone},
		})
	}
	return narrowed, nil
}

func (st *Station) Check() CheckResult {
	out := CheckResult{OK: []string{}, Failed: []CheckFailure{}}

	for _, row := range st.Instances() {
		if !row.Active {
			continue
		}
		st.checkone(row, &out)
	}

	return out
}

// checkone is one instance's turn, with the panic seam recovered: this
// port panics for construction-time misconfiguration (the wrap-order
// guard, a second binding of one instance), and Check exists to turn
// exactly those into ONE report at a moment somebody is watching.
func (st *Station) checkone(row Instance, out *CheckResult) {
	defer func() {
		recovered := recover()
		if nil == recovered {
			return
		}
		if serr, is := recovered.(*Error); is {
			out.Failed = append(out.Failed, CheckFailure{
				Name: row.Name, Code: serr.Code, Message: serr.Error(),
			})
			return
		}
		panic(recovered)
	}()

	{
		if entry := FactoryFor(row.API); nil != entry {
			resolved, err := st.FeaturesOf(row.Name)
			if nil != err {
				out.Failed = append(out.Failed, checkfailure(row.Name, err))
				return
			}
			if faults := CheckFeatures(resolved.Merged, entry.Descriptor); 0 < len(faults) {
				out.Failed = append(out.Failed, CheckFailure{
					Name: row.Name, Code: faults[0].Code,
					Message: FaultMessages(faults),
				})
				return
			}
		}

		if _, err := st.SDK(row.Name); nil != err {
			out.Failed = append(out.Failed, checkfailure(row.Name, err))
			return
		}
		out.OK = append(out.OK, row.Name)
	}
}

func checkfailure(name string, err error) CheckFailure {
	code := ""
	if serr, is := err.(*Error); is {
		code = serr.Code
	}
	return CheckFailure{Name: name, Code: code, Message: err.Error()}
}

func (st *Station) Warm(names []string) WarmResult {
	wanted := names
	if nil == wanted {
		wanted = []string{}
		for _, row := range st.Instances() {
			if row.Active {
				wanted = append(wanted, row.Name)
			}
		}
	}

	warmed := []string{}
	missed := []string{}

	bysecret := map[string][]string{}
	order := []string{}
	for _, name := range wanted {
		st.mu.Lock()
		entry, live := st.registry[name]
		_, declared := st.profile.Sdk[name]
		st.mu.Unlock()

		if !live && !declared {
			missed = append(missed, name)
			continue
		}

		secretname := ""
		if live {
			secretname = entry.Secretname
		}
		if "" == secretname {
			secretname = asString(st.BlockFor(name)["secret"])
		}
		if "" == secretname {
			secretname = SecretnameDefault(st.DeclaredRef(name))
		}

		if _, has := bysecret[secretname]; !has {
			order = append(order, secretname)
		}
		bysecret[secretname] = append(bysecret[secretname], name)
	}

	sort.Strings(order)
	results := make([]bool, len(order))
	var wg sync.WaitGroup
	for i, secretname := range order {
		wg.Add(1)
		go func(i int, secretname string) {
			defer wg.Done()
			_, err := st.broker.value(bysecret[secretname][0], secretname)
			results[i] = nil == err
		}(i, secretname)
	}
	wg.Wait()

	for i, secretname := range order {
		for _, name := range bysecret[secretname] {
			if results[i] {
				warmed = append(warmed, name)
			} else {
				missed = append(missed, name)
			}
		}
	}

	sort.Strings(warmed)
	sort.Strings(missed)
	return WarmResult{Warmed: warmed, Missed: missed}
}

func (st *Station) Instances() []Instance {
	st.mu.Lock()
	defer st.mu.Unlock()

	names := make([]string, 0, len(st.profile.Sdk))
	for name := range st.profile.Sdk {
		names = append(names, name)
	}
	sort.Strings(names)

	out := make([]Instance, 0, len(names))
	for _, name := range names {
		block := st.profile.Sdk[name]
		entry, live := st.registry[name]
		rung := "none"
		if live {
			rung = entry.Rung
		}
		out = append(out, Instance{
			Name: name, API: RefApi(name),
			// `active: false` means BARRED FROM RUNNING - a declaration
			// that stays in the file and here while being refused a
			// client.
			Active: false != block["active"],
			Live:   live, Rung: rung, Block: block,
		})
	}
	return out
}

// Plugins lists one entry per LIVE INSTANCE, and it is EXHAUSTIVE:
// auto-tagged entries are NOT collapsed here, because inspection, health
// reporting and cleanup all need to enumerate the clients Create()
// produced, which is exactly when you most want them. Truncation is a
// presentation decision and belongs to Status().
func (st *Station) Plugins() []PluginEntry {
	st.mu.Lock()
	defer st.mu.Unlock()
	names := make([]string, 0, len(st.registry))
	for name := range st.registry {
		names = append(names, name)
	}
	sort.Strings(names)

	out := make([]PluginEntry, 0, len(names))
	for _, name := range names {
		entry := st.registry[name]
		warnings := make([]string, len(entry.Warnings))
		copy(warnings, entry.Warnings)
		out = append(out, PluginEntry{
			Name: entry.Name, API: entry.API, Slug: entry.Slug,
			Descriptor: entry.Descriptor, Rung: entry.Rung,
			Secretname: entry.Secretname, Client: entry.Client,
			Warnings: warnings,
		})
	}
	return out
}

// DescriptorOf accepts an INSTANCE name and returns its api's descriptor
// - one object shared by every instance of that api (§7.4). The error
// names the known instances (design §7's affordance, applied at the
// library seam).
func (st *Station) DescriptorOf(name string) (map[string]any, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	entry, has := st.registry[name]
	if !has {
		known := make([]string, 0, len(st.registry))
		for one := range st.registry {
			known = append(known, one)
		}
		sort.Strings(known)
		return nil, fail("station_no_plugin", "unknown plugin \""+name+
			"\"; known: ["+strings.Join(known, ", ")+"]")
	}
	return entry.Descriptor, nil
}

func (st *Station) CanonicalDescriptor(name string) (string, error) {
	descriptor, err := st.DescriptorOf(name)
	if nil != err {
		return "", err
	}
	return CanonicalSerialize(descriptor), nil
}

func (st *Station) Events() []Event {
	return st.buffer.events()
}

// Tap subscribes to the live event stream; the returned func
// unsubscribes. Callbacks are serialized and a panicking tap never fails
// an operation (design §6).
func (st *Station) Tap(fn func(Event)) func() {
	return st.buffer.tap(fn)
}

func (st *Station) Status() Status {
	plugins := []PluginStatus{}
	for _, entry := range st.Plugins() {
		plugins = append(plugins, PluginStatus{
			Name: entry.Name, API: entry.API, Slug: entry.Slug, Rung: entry.Rung,
		})
	}

	st.mu.Lock()
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

func (st *Station) Close() {
	st.mu.Lock()
	if st.closed {
		st.mu.Unlock()
		return
	}
	unmatched := []string{}
	for name := range st.profile.Sdk {
		if _, has := st.registry[name]; !has {
			unmatched = append(unmatched, name)
		}
	}
	sort.Strings(unmatched)
	st.closed = true
	st.mu.Unlock()

	for _, name := range unmatched {
		st.emit(Event{
			T: nowMs(), Kind: "station",
			Meta: map[string]any{
				"warn": "profile plugin key \"" + name +
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
