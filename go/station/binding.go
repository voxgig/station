// The station side of the plugin contract (design §3), in ONE place:
// Bind() is what the generated station feature calls from its Init, so
// every rule here - wrap position, registration, placeholder placement,
// copy-on-inject - is the library's, never the adapter's. The adapter
// (sdkgen-station's tm/go template) is a thin shell that only translates
// the generated SDK's concrete types into this seam.
//
// A port of typescript/src/adapter.ts featureBinding, which is
// canonical. Go has no carried adapterFeature: a hand-written library
// cannot implement each generated SDK's own Feature interface, so the
// retrofit path for pre-station SDKs is regeneration with the feature
// (design §3.1's no-extend-seam case) and the inverted binding is the
// primary form.
package station

import "strings"

// TransportFunc is the language-neutral transport shape the middleware
// wraps: the SDK's own per-request context rides through as an opaque
// value (it keys the per-op correlation state).
type TransportFunc func(opctx any, fullurl string, fetchdef map[string]any) (any, error)

// OpInfo is what the adapter extracts from the SDK's op context for the
// hook bridge - entity and op in the descriptor's lowercase spelling,
// and the result outcome ('ok' | 'err' | 'unknown').
type OpInfo struct {
	Entity  string
	Op      string
	Outcome string
}

// BindSpec is the generated adapter's view of one SDK client at feature
// Init time. Everything the binding needs crosses here once, so the
// library never learns the generated package's types.
type BindSpec struct {
	// Client is the SDK client value, the identity for the bound-twice
	// and second-arrival checks.
	Client any
	// Config is the SDK's embedded config (ctx.Config).
	Config map[string]any
	// SDKOptions is the client's resolved options map (ctx.Options).
	// MUTATED by Bind: the credential placeholder is planted in
	// options["apikey"], and a profile base may be applied.
	SDKOptions map[string]any
	// FeatureOpts is the station feature's own options entry
	// (options.feature.station), carrying the handle, calleropts, and
	// the config.options values (secret, ...).
	FeatureOpts map[string]any
	// FeatureNames is the client's feature list, by name, in init order
	// - the §3.3 position guard reads it (go's wrap-position check is
	// the exported Features name list; funcs cannot carry a marker).
	FeatureNames []string
	// Mode reports the client mode at call time ('live' | 'test'):
	// injection is skipped whenever the base transport is a mock.
	Mode func() string
	// Fetch is the CURRENT transport at Init time - the wrap's inner.
	Fetch TransportFunc
	// SetFetch installs the wrapped transport on the live utility
	// instance (never on a copy - GetUtility() copies).
	SetFetch func(TransportFunc)
}

// FeatureBinding is the bound station side the adapter forwards its
// hooks to.
type FeatureBinding struct {
	// Name is the INSTANCE this binding belongs to (§7.1) - `api$tag`,
	// or a bare api slug for the untagged one. Every event it emits is
	// keyed on it.
	Name string
	st   *Station
}

// Bind resolves the station this activation binds to - an explicit
// handle in the feature options (st.Options() passes one), else the
// ambient instance - and makes the §3 binding: registration, wrap
// position verified, transport wrapped with copy-on-inject, hooks
// bridged to op events. No station open -> nil: an activated feature
// with no opened station is an inert no-op that emits nothing and fails
// nothing (design §3.1). Misbinding - wrong wrap position, one client
// bound twice - PANICS with the catalog code, construction-time
// misconfiguration in the generated SDKs' own idiom.
func Bind(spec *BindSpec) *FeatureBinding {
	if nil == spec {
		return nil
	}

	st, _ := spec.FeatureOpts["station"].(*Station)
	if nil == st {
		st = Current()
	}
	if nil == st {
		return nil
	}

	// Same construction, second arrival: the first bind won, this one is
	// inert. See Station.boundEntry.
	if nil != st.boundEntry(spec.Client) {
		return nil
	}

	// Position guard (design §3.3): the wrap must sit immediately
	// outside the base transport - inside retry/cache/ratelimit - or
	// its http events stop being wire truth. Position in the client's
	// feature list IS init order, so verify it and fail loudly.
	names := spec.FeatureNames
	self, testAt := -1, -1
	for i, name := range names {
		if "station" == name && 0 > self {
			self = i
		}
		if "test" == name && 0 > testAt {
			testAt = i
		}
	}
	expected := 0
	if 0 <= testAt {
		expected = testAt + 1
	}
	if self != expected {
		panic(fail("station_wrap_order",
			"station must init immediately after the base transport; "+
				"feature order is ["+joinNames(names)+"]"))
	}

	reg := st.register(spec.Client, spec.Config, spec.SDKOptions, spec.FeatureOpts)
	entry := reg.entry
	name := entry.Name

	// Base URL precedence (design §3.5): caller opts (7) beat the
	// profile (4), which beats the SDK's config default (1) already in
	// options.base. calleropts is what st.Options() was handed, so a
	// caller-set base wins and an unset one takes the profile's.
	calleropts, hasCalleropts := spec.FeatureOpts["calleropts"].(map[string]any)
	if hasCalleropts && nil == calleropts["base"] {
		if base := asString(reg.block["base"]); "" != base {
			spec.SDKOptions["base"] = base
		}
	}

	// Policy allowlists (design §16): `allow.op` / `allow.method` are
	// the same vocabulary the SDKs already enforce (options.allow, and
	// the raw-access gate every target implements), so station sets
	// these SDK options from policy and enforcement stays in the SDK's
	// own pipeline. The SDK's option form is a comma-separated string,
	// so the policy's list joins into it.
	//
	// Unlike `base` above, which is a DEFAULT the caller may override,
	// an allowlist is ENFORCEMENT: policy wins over whatever the options
	// carry, on exactly the keys it sets. Applied at binding time, which
	// is inside the constructor, and on the one entry point both the
	// declarative and the inverted path come through.
	if pallow, is := asMap(reg.block["policy"])["allow"].(map[string]any); is {
		allow := map[string]any{}
		for k, v := range asMap(spec.SDKOptions["allow"]) {
			allow[k] = v
		}
		if op, joined := joinPolicyList(pallow["op"]); joined {
			allow["op"] = op
		}
		if method, joined := joinPolicyList(pallow["method"]); joined {
			allow["method"] = method
		}
		spec.SDKOptions["allow"] = allow
	}

	if "none" != entry.Rung {
		placeholder := reg.placeholder

		// A real credential already resident in the options is hoisted
		// into the broker and replaced by the placeholder before
		// construction completes (design §3.1) - OptionsMap() and
		// Prepare() output become placeholder-safe from here on.
		if resident := asString(spec.SDKOptions["apikey"]); "" != resident &&
			placeholder != resident {
			st.hoist(name, resident)
		}
		spec.SDKOptions["apikey"] = placeholder
	}

	// Wrap the transport. Copy-on-inject (design §5.3) happens inside
	// Station.transport; auth-inactive plugins skip credential planning
	// but the wrap still observes (design §5.3).
	inner := spec.Fetch
	mode := spec.Mode
	if nil == mode {
		mode = func() string { return "live" }
	}
	spec.SetFetch(func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
		return st.transport(entry, mode, inner, opctx, fullurl, fetchdef)
	})

	return &FeatureBinding{Name: name, st: st}
}

// joinPolicyList joins a policy allowlist into the SDK's own
// comma-separated option form. A non-list is not joined - the shape
// rejects it by path, and coercing here would hide that.
func joinPolicyList(val any) (string, bool) {
	items, is := val.([]any)
	if !is {
		if texts, is := val.([]string); is {
			return strings.Join(texts, ","), true
		}
		return "", false
	}
	out := make([]string, 0, len(items))
	for _, one := range items {
		out = append(out, asString(one))
	}
	return strings.Join(out, ","), true
}

// PrePoint opens the per-op correlation (design §3 item 3): the http
// events the middleware emits for this op context carry the same corr as
// the op event PreDone/PreUnexpected will emit.
func (binding *FeatureBinding) PrePoint(opctx any) {
	binding.st.opStart(opctx)
}

// PreDone closes the op with the outcome the adapter read from the
// result ('ok' | 'err' | 'unknown').
func (binding *FeatureBinding) PreDone(opctx any, info OpInfo) {
	binding.st.opEvent(binding.Name, opctx, info, info.Outcome)
}

// PreUnexpected closes the op as 'unexpected' - the error-path hook the
// SDKs fire for failures that never reach PreDone.
func (binding *FeatureBinding) PreUnexpected(opctx any, info OpInfo) {
	binding.st.opEvent(binding.Name, opctx, info, "unexpected")
}

func joinNames(names []string) string {
	out := ""
	for i, name := range names {
		if 0 < i {
			out += ", "
		}
		out += name
	}
	return out
}
