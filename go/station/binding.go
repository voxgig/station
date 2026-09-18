package station

import "strings"

type TransportFunc func(opctx any, fullurl string, fetchdef map[string]any) (any, error)

// OpInfo is what the adapter extracts from the SDK's op context for the
// hook bridge - entity and op in the descriptor's lowercase spelling,
// and the result outcome ('ok' | 'err' | 'unknown').
type OpInfo struct {
	Entity  string
	Op      string
	Outcome string
}

type BindSpec struct {
	Client       any
	Config       map[string]any
	SDKOptions   map[string]any
	FeatureOpts  map[string]any
	FeatureNames []string
	Mode         func() string
	Fetch        TransportFunc
	SetFetch     func(TransportFunc)
}

type FeatureBinding struct {
	Name string
	st   *Station
}

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

func (binding *FeatureBinding) PrePoint(opctx any) {
	binding.st.opStart(opctx)
}

func (binding *FeatureBinding) PreDone(opctx any, info OpInfo) {
	binding.st.opEvent(binding.Name, opctx, info, info.Outcome)
}

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
