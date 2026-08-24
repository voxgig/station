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
//
// The DECLARATIVE front door (design §6) is here too - Instances, SDK,
// Create, FeaturesOf, Check, Warm - resting on the process-global
// factory table in factory.go. §6.3's loader is NOT here and cannot be:
// Go links its dependencies, so there is no import-by-name at run time.
// See README.md for the §5.4 divergence in full.
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
	// RepoScoped, when non-nil, decides §6.3's review boundary outright.
	// READ FIRST, before anything is inferred: inferring first makes
	// `repoScoped: false` unsettable for any caller passing a config in
	// code, which is every test of the rule.
	RepoScoped *bool
	// Load is ACCEPTED AND INERT here (§6.3, §5.4 item 4): this port has
	// no loader to switch off. The field exists so one config and one
	// call site serve a polyglot fleet.
	Load *bool
}

// PluginEntry is one registered INSTANCE (design §3.2, §7.1).
type PluginEntry struct {
	// Name is the instance ref - `api$tag`, or a bare api slug for the
	// untagged one. THE REGISTRY KEY.
	Name string
	// API is what groups an instance's siblings.
	API string
	// Slug is retained and equals API: it is what `slug` always meant
	// here, and the two are the same string for an untagged instance.
	Slug       string
	Descriptor map[string]any
	Rung       string // 'none' | 'R1'
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
	// Ordered is the resolved order, OUTERMOST FIRST, including the
	// implicit `station` row §8.4 pins.
	Ordered []string `json:"ordered"`
	// Merged is the user's own merge result - `station` is never in it.
	Merged map[string]any `json:"merged"`
	// From is feature -> option key -> the config level that set it.
	From map[string]map[string]string `json:"from"`
	// Declared is the merged map's DECLARATION ORDER, which §8.4 uses as
	// its last tie-break and a Go map cannot keep (see order.go).
	Declared []string `json:"declared"`
}

// FeatureRow is one row of the fleet view (design §8.7).
type FeatureRow struct {
	Instance string                       `json:"instance"`
	API      string                       `json:"api"`
	Ordered  []string                     `json:"ordered"`
	Merged   map[string]any               `json:"merged"`
	From     map[string]map[string]string `json:"from"`
}

// FeatureFilter narrows the fleet view. Go cannot overload on a string,
// so the string shorthand is LooseFilter() and this is the object form -
// the only one that can express the question the view exists for:
// {Feature: "debug"}, "is debug on anywhere?", the one that is twenty
// greps today.
type FeatureFilter struct {
	Instance string
	API      string
	Feature  string
	// Loose matches an instance name OR an api, which is what the string
	// shorthand means.
	Loose bool
}

// LooseFilter is the string shorthand: "this instance or this api".
func LooseFilter(text string) *FeatureFilter {
	return &FeatureFilter{Instance: text, API: text, Loose: true}
}

// CheckFailure is one instance Check() could not stand up.
type CheckFailure struct {
	Name    string `json:"name"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// CheckResult is the CI answer (design §6.6).
type CheckResult struct {
	OK     []string       `json:"ok"`
	Failed []CheckFailure `json:"failed"`
}

// WarmResult is the batch secret resolution (design §5.5). Both lists
// are sorted.
type WarmResult struct {
	Warmed []string `json:"warmed"`
	Missed []string `json:"missed"`
}

// Status is the solo status surface (design §6).
type Status struct {
	Mode    string            `json:"mode"`
	Profile string            `json:"profile"`
	Plugins []PluginStatus    `json:"plugins"`
	Events  EventBufferStatus `json:"events"`
}

// PluginStatus projects one live instance. §7.1: the registry is keyed
// by INSTANCE, so a status page that projects only `slug` shows two
// indistinguishable rows for `stripe$test` and `stripe$live` and omits
// the names it is keyed by - an operator cannot tell which one is
// unhealthy. `slug` stays for compatibility; `name` and `api` are what
// answer the question.
type PluginStatus struct {
	Name string `json:"name"`
	API  string `json:"api"`
	Slug string `json:"slug"`
	Rung string `json:"rung"`
}

// describedSDK is one api's shared descriptor (design §7.4).
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
	// registry is keyed by INSTANCE NAME (§7.1). Two clients of one api
	// is the NORMAL case now; two bindings of one instance is still the
	// error it was.
	registry map[string]*PluginEntry
	// clients is SDK()'s cache; Create() deliberately does not use it.
	clients map[string]any
	// aliasOf maps an auto-assigned tag to the DECLARED instance it
	// stands for (§5.3). Beside the registry rather than inside it,
	// because the mapping exists before construction and BlockFor needs
	// it during registration.
	aliasOf map[string]string
	// descriptorCache is the shared per-api descriptor (§7.4).
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

	// §6.3: EXPLICIT WINS, then an in-code config (the application wrote
	// it, so it is repo-scoped by construction), then where the file was
	// found. Inferring BEFORE reading the explicit option is a real
	// precedence bug: it makes RepoScoped=false unsettable for any
	// caller passing a config in code.
	repoScoped := false
	if nil != opts.RepoScoped {
		repoScoped = *opts.RepoScoped
	} else if incode {
		repoScoped = true
	} else {
		repoScoped = "user" != ConfigScope(opts.Folder)
	}

	// Normalize, then validate (design §4.2). A malformed station.json
	// fails New()/Open() with EVERY error at once - an eighteen-instance
	// config must not die because the eighteenth has a typo'd package
	// name.
	//
	// ResolveProfile then reads the RAW config, NOT the normalized one.
	// The normalized form is an input to validation and to nothing else:
	// block defaults synthesized before the profile merge would let a
	// one-key overlay overwrite the base's `active: false` and silently
	// re-enable a barred integration (§3.3, §4.2).
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

// RepoScoped reports which side of §6.3's review boundary this station's
// config came from.
func (st *Station) RepoScoped() bool {
	return st.repoScoped
}

// --- the inverted binding form (design §3.1) ---

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

// --- registration (design §3 item 1, called by Bind) ---

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

// BlockFor is the profile block that governs an instance - its own if
// the profile declares it, otherwise its API'S.
//
// ResolveProfile builds profile.Sdk from the declared refs alone (an api
// block declares no instance, §3.1), which leaves an IMPERATIVE instance
// - named but never written into config - with no block at all, so the
// api-level `secret`, `base` and most seriously `policy.hosts` did not
// reach it, and a profile that denied egress everywhere denied nothing
// for a tagged client.
//
// ONE RULE, ONE PLACE: registration and the transport seam both ask
// here, because them disagreeing is how the credential and the allowlist
// came apart in the first place.
func (st *Station) BlockFor(name string) map[string]any {
	declared := st.DeclaredRef(name)
	st.mu.Lock()
	defer st.mu.Unlock()
	if block, has := st.profile.Sdk[declared]; has {
		return block
	}
	return st.profile.Api[RefApi(name)]
}

// DeclaredRef is the DECLARED instance an assigned tag stands for, or
// the name itself. Create("stripe$prod") registers under `stripe$1`, and
// every question about that client's configuration - its secret, its
// base, its egress policy - is a question about `stripe$prod`.
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

	// Secret name precedence: the feature option (in-code, design §9
	// config.options.secret) beats the profile, which beats the
	// INSTANCE-derived default.
	//
	// §5.1: SecretnameDefault takes the instance name, not the api slug.
	// For an untagged instance the two are the same string, so the
	// single-instance case is unchanged to the byte. And the DEFAULT
	// takes the DECLARED name, not the assigned tag: `stripe$1` created
	// from `stripe$test` derives `stripe_test.apikey`, so every
	// per-request client of one instance shares one broker cache entry
	// (§5.3).
	//
	// The descriptor's own auth.secretname stays the API-level default
	// and is NOT used here (§7.4): one descriptor is shared by every
	// instance of an api and cannot hold two instance-derived names.
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

// describe is the per-api descriptor cache (§7.4). THE DESCRIPTOR IS
// SHARED because it describes the API rather than any use of it: at 26
// instances over 20 apis that is 20 normalizations, not 26, and the
// canonical serialization the proxy dedupes registrations by is computed
// once per api too.
//
// Normalized with NO per-instance features, so the shared value holds
// only api-stable metadata - which is what the factory table already
// does at provide time. Per-instance activation is FeaturesOf's answer;
// a cache keyed by slug but built from the first instance's feature map
// would make DescriptorOf construction-order-dependent.
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

// --- the transport middleware (design §3.3, §5.3) ---

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

	// Egress policy (design §16), solo half: the hosts allowlist is
	// enforced at the seam every request crosses. When a policy is
	// present, redirects come back manual - a 3xx is a response like
	// any other, so a Location off the allowlist cannot pull an
	// automatic credentialed follow-up to an unapproved host (§8.2's
	// rule, applied at the library seam).
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
		// §7.4: THE EFFECTIVE NAME, resolved once at registration and
		// stored on the entry, read here with NO FALLBACK. Re-deriving
		// it here got the precedence right and the fallback wrong: the
		// descriptor's auth.secretname is the API-level default, and one
		// descriptor is shared by every instance of an api - so a tagged
		// instance with no explicit `secret` read `stripe.apikey` where
		// registration had recorded `stripe_test.apikey`.
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

// --- the declarative front door (design §6) ---

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

// Create returns an UNCACHED client from the same resolved config plus
// overrides, for the case that genuinely wants a distinct one - a
// per-request credential scope, a test double. Deliberately the longer
// name.
//
// It registers under an AUTO-ASSIGNED TAG, because every constructed
// adapter registers under its instance name and station_bound_twice
// fires on a second binding of one name: a second Create("stripe") would
// otherwise fail, which is exactly the per-request case this exists for.
// The tag is the lowest unused positive integer, so an auto-tagged
// instance is an ORDINARY instance rather than a parallel identity
// scheme - Plugins(), the placeholder, the event stream and
// station_bound_twice all keep working on one identity model.
func (st *Station) Create(name string, overrides map[string]any) (any, error) {
	return st.Build(name, st.Autotag(name), overrides)
}

// Autotag is the lowest positive integer tag not already taken, by a
// LIVE instance or a DECLARED one.
//
// THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`,
// and until something constructs it the registry says false - so
// Create("stripe$prod") would take that identity, Instances() would
// report the declared `stripe$1` as live with the wrong client, and a
// later SDK("stripe$1") would fail station_bound_twice against a binding
// that was never its own. Declaration reserves the name whether or not
// it has been built.
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

	// §8.5 VALIDATES HERE, not only in Check(). The schema arrives with
	// the factory, so the moment a factory is resolved is the first
	// moment validation is possible - and running it in Check() alone
	// left production SDK() silently ignoring an unknown option like
	// `retry.retires`. One call here closes it, because EVERY path to a
	// constructor comes through this line.
	if faults := CheckFeatures(resolved.Merged, entry.Descriptor); 0 < len(faults) {
		return nil, fail(faults[0].Code, FaultMessages(faults))
	}

	// §8.4: compose the merged feature map into the form the constructor
	// takes. Station's own entry is composed AFTER the user merge and
	// always wins, which is why `station` is dropped here and re-added by
	// OptionsFor: a config file that can switch off the component
	// reading it is not a surface, it is a trap. `feature.station` is
	// already station_feature_reserved at validation, so this is the
	// second half of one rule rather than a second rule.
	//
	// GO CANNOT CARRY THE ORDER IN THE MAP - a Go map has none, and the
	// generated Go constructor takes options["feature"] as a map. The
	// order is RESOLVED here (so a cycle or a pin violation fails the
	// build) and REPORTED by FeaturesOf; what a Go SDK actually inits in
	// is its own generated feature list, whose one station-relevant
	// invariant - the pin - Bind still verifies and fails loudly with
	// station_wrap_order. README.md states the divergence.
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

	// RECORD THE ALIAS, NOT THE FIELDS. Carrying the declared `secret`
	// through the feature options and stopping there leaves `policy`,
	// `base` and everything else behind, so an auto-tagged client
	// silently loses its declared instance's HOSTS ALLOWLIST and falls
	// back to the wider api-level one. Recording what the tag STANDS FOR
	// is one rule that every lookup already goes through.
	//
	// Only when the tag was ASSIGNED - a caller naming its own is naming
	// an instance, not aliasing one.
	registerAs := name
	if "" != as && as != name {
		st.mu.Lock()
		st.aliasOf[as] = name
		st.mu.Unlock()
		registerAs = as
	}

	// The instance name reaches the adapter the same way it does on the
	// imperative path, so registration has one spelling (§7.5). Go has
	// no carried adapter - a hand-written library cannot implement each
	// generated SDK's own Feature interface - so the retrofit path here
	// is regeneration with the station feature installed, and the
	// constructor's own feature is what binds.
	return entry.Construct(st.OptionsFor(registerAs, opts)), nil
}

// ResolveFactory has TWO paths in this port (§5.4 item 3):
// self-registration through a generated package's func init(), and
// Provide. THE LOADER IS THE THIRD PATH EVERYWHERE ELSE AND DOES NOT
// EXIST HERE, so the error names only the remedies Go actually offers -
// a message telling a Go user to set `api.<slug>.package` would send
// them down a road with no end.
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

// LoaderPackage always returns "" here, and says why once per api at
// open (§5.4 item 2). `package` and `export` stay IN THE GRAMMAR - they
// are shape keys, the corpus validates configs carrying them, and
// removing them would break one-config-file-serves-a-polyglot-fleet -
// but this port cannot honour them, and silence about that is worse than
// a warning.
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

// FeaturesOf is the merged, ordered feature set for one instance, WITH
// PROVENANCE (§8.7): which config level set each value.
//
// Provenance is the half that makes a fleet view usable rather than
// merely correct - at 26 instances "why is retry off here" is the
// question, and a merged map alone cannot answer it.
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

	// LEVELS: one label per source, in the §3.3 order.
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

	// Policy budget (design §16): rps/concurrency ceilings ride "the SDK
	// `ratelimit` feature, configured by station". Composed HERE, into
	// the merged map every consumer reads, rather than patched in at
	// construction alone - so Build orders it with the ordinary
	// constraint-and-band rules, Check's §8.5 pass validates it against
	// the SDK's own declaration (a budget on an SDK with no ratelimit
	// feature is station_feature_unknown, not a setting that quietly did
	// nothing), and the fleet view answers "is ratelimit on?" truthfully.
	//
	// `rps` maps to the token bucket's refill `rate` (per second - the
	// same unit); `concurrency` to its capacity `burst`, the number of
	// requests that can be in flight from a full bucket. POLICY WINS
	// over a `feature.ratelimit` config entry on the keys it sets - it
	// is enforcement, not a default - and other tuning keys survive
	// beside it.
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

	// THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station` is
	// never in Merged - feature.station is reserved and rejected at
	// validation (§8.4) - so without it CheckPin finds no station row
	// and is a PERMANENT NO-OP: a constraint like
	// `retry.order.after: "station"` would be treated as vacuous rather
	// than rejected, and the reported order would omit the one feature
	// whose position is supposedly pinned.
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

// Check eagerly resolves and constructs every ACTIVE declared instance -
// for CI (design §6.6). The point is to turn availability errors, which
// are deliberately deferred to first use, into ONE failure at a moment
// somebody is watching.
func (st *Station) Check() CheckResult {
	out := CheckResult{OK: []string{}, Failed: []CheckFailure{}}

	for _, row := range st.Instances() {
		if !row.Active {
			continue
		}

		// §8.5 runs FIRST and needs no construction: the schema arrives
		// with the factory, not with a live client, so a feature typo is
		// a CI failure rather than a setting that quietly did nothing in
		// production.
		if entry := FactoryFor(row.API); nil != entry {
			resolved, err := st.FeaturesOf(row.Name)
			if nil != err {
				out.Failed = append(out.Failed, checkfailure(row.Name, err))
				continue
			}
			if faults := CheckFeatures(resolved.Merged, entry.Descriptor); 0 < len(faults) {
				out.Failed = append(out.Failed, CheckFailure{
					Name: row.Name, Code: faults[0].Code,
					Message: FaultMessages(faults),
				})
				continue
			}
		}

		if _, err := st.SDK(row.Name); nil != err {
			out.Failed = append(out.Failed, checkfailure(row.Name, err))
			continue
		}
		out.OK = append(out.OK, row.Name)
	}

	return out
}

func checkfailure(name string, err error) CheckFailure {
	code := ""
	if serr, is := err.(*Error); is {
		code = serr.Code
	}
	return CheckFailure{Name: name, Code: code, Message: err.Error()}
}

// Warm batch-resolves secrets (design §5.5).
//
// With no names it warms the ACTIVE declared instances only, because
// reaching for a credential belonging to a disabled integration is the
// wrong default. Warm(names) warms exactly what it is given, inactive
// included, because an explicit name is an explicit request.
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

	// THE REGISTRY IS THE AUTHORITY: a registered instance already
	// carries the resolved name, in-code `secret` feature option
	// included. A NAME NOBODY DECLARED OR REGISTERED IS A MISS, not a
	// lookup - a wider fallback would let a typo like `stripe$prodd`
	// derive a secret name, call the provider, and report a nonexistent
	// instance `warmed` off a shared api-level credential. Registered OR
	// declared, and nothing else.
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

	// ONE RESOLUTION PER DISTINCT SECRET NAME, run CONCURRENTLY. The
	// broker's resolution cache is keyed by secret name (§5.3), so
	// several instances sharing one api-level `secret` should cost one
	// round-trip - and firing them together without deduplication would
	// race past the cache and make several. Resolving serially instead
	// makes Warm cost the SUM of every provider round-trip, which
	// defeats the one thing the method exists for.
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

// Instances lists every DECLARED instance, sorted by name.
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

// --- the query/observe surface (design §3.2, §6) ---

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

// CanonicalDescriptor is the §4 canonical serialization of an instance's
// descriptor.
func (st *Station) CanonicalDescriptor(name string) (string, error) {
	descriptor, err := st.DescriptorOf(name)
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

// Status is the solo status surface (design §6).
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

// Close flushes (solo: nothing in flight), then warns on declared
// instances that matched no registered client - a typo'd key silently
// configuring nothing is the worst outcome for a secrets-and-policy file
// (design §11). Idempotent.
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
