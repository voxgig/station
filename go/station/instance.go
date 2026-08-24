// The instance ref grammar (design §6.1), pinned by the `instanceref`
// corpus section.
//
// A port of the instanceRef/checkref half of typescript/src/Station.ts,
// which is canonical. It lives in its own file here because Go has no
// class body to hang free functions off, and this is the one piece of
// Station.ts that is pure over (api, opts).
package station

import "regexp"

// The ref grammar is the JOINT identity model's (station-and-plugin.md
// §2, plugin design §4): a name is a package-ish specifier, a tag is not
// - it MAY start with a digit, because auto-tagging assigns integer
// tags, and admits neither `@` nor `/`; both cap at 1024; the split is
// on the FIRST `$`, so `a$b$c` is a good name with a bad tag.
var (
	refNameRe = regexp.MustCompile(`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`)
	refTagRe  = regexp.MustCompile(`^[a-zA-Z0-9.~_-]+$`)
)

const refMax = 1024

// CheckInstanceName reports whether a ref's name half is well formed.
func CheckInstanceName(name string) bool {
	if 0 == len(name) || refMax < len(name) {
		return false
	}
	return refNameRe.MatchString(name)
}

// CheckInstanceTag reports whether a ref's tag half is well formed. The
// EMPTY TAG IS AN ORDINARY TAG: the single-instance case writes no tag
// and never learns tags exist.
func CheckInstanceTag(tag string) bool {
	if 0 == len(tag) {
		return true
	}
	if refMax < len(tag) {
		return false
	}
	return refTagRe.MatchString(tag)
}

// CheckRef validates a ref against the joint grammar and returns its
// CANONICAL spelling: a trailing `$` (empty tag) is never kept, so
// `stripe$` and `stripe` are one registry key rather than two.
func CheckRef(ref string) (string, error) {
	name, tag, tagged := cutref(ref)
	if !CheckInstanceName(name) {
		return "", fail("station_instance_api",
			"invalid instance name \""+name+"\" in ref \""+ref+"\": a name "+
				"starts with a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, "+
				"max 1024 (§6.1)")
	}
	if !CheckInstanceTag(tag) {
		return "", fail("station_instance_api",
			"invalid instance tag \""+tag+"\" in ref \""+ref+"\": a tag uses "+
				"`[a-zA-Z0-9.~_-]`, max 1024 (§6.1)")
	}
	if !tagged || "" == tag {
		return name, nil
	}
	return ref, nil
}

func cutref(ref string) (name string, tag string, tagged bool) {
	for i := 0; i < len(ref); i++ {
		if '$' == ref[i] {
			return ref[:i], ref[i+1:], true
		}
	}
	return ref, "", false
}

func checkapi(api string, ref string) error {
	if RefApi(ref) != api {
		return fail("station_instance_api",
			"instance \""+ref+"\" names api \""+RefApi(ref)+"\", but the SDK "+
				"passed is api \""+api+"\"; `as` is a tag, not a free name (§6.1)")
	}
	return nil
}

// InstanceRef resolves the instance name one construction registers
// under. §6.1: `as` IS A TAG, NOT A FREE NAME.
//
// The api comes from the SDK being built, so the resulting ref is
// `<api>$<tag>` and multi-instance works imperatively too. A full ref is
// also accepted and is VALIDATED: its name must equal the api slug, or
// it is station_instance_api. An `as` that took an arbitrary name would
// reintroduce exactly the second-identity problem the ref re-key
// removed - under the ref invariant `as: "solar-eu"` would denote the
// untagged `solar-eu` DEFINITION rather than an instance of the SDK just
// handed in, and registry grouping, api defaults and every ref consumer
// would disagree about what it is.
//
// A bare build with no name falls back to the api slug, which is today's
// behaviour and why the single-instance case is unchanged to the byte.
func InstanceRef(api string, fopts map[string]any) (string, error) {
	if explicit := textopt(fopts, "instance"); "" != explicit {
		if err := checkapi(api, explicit); nil != err {
			return "", err
		}
		return CheckRef(explicit)
	}

	as := textopt(fopts, "as")

	// The bare fallback is the SLUG - a name, never a ref: a `$` in it
	// is an invalid name, not an implicit tag.
	if "" == as {
		if !CheckInstanceName(api) {
			return "", fail("station_instance_api",
				"invalid instance name \""+api+"\": a name starts with a letter "+
					"or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (§6.1)")
		}
		return api, nil
	}

	// A `$`-LESS STRING IS ALWAYS A TAG, and a `$`-bearing one is a full
	// ref validated against the api.
	//
	// §6.1 gives both branches and does not say how to disambiguate a
	// `$`-less string, which is a real ambiguity because a bare name is
	// itself a valid (untagged) ref: `as: "stripe"` on api `stripe`
	// could read as the untagged ref `stripe` or as tag `stripe`. It is
	// read as a TAG, giving `stripe$stripe`, because §6.1 says twice and
	// emphatically that `as` is a tag rather than a free name, and a
	// rule with no exceptions is the one that ports the same way twenty
	// times. Someone who wants the untagged instance passes no `as` at
	// all, which is the documented spelling for it.
	if _, _, tagged := cutref(as); !tagged {
		return CheckRef(api + "$" + as)
	}
	if err := checkapi(api, as); nil != err {
		return "", err
	}
	return CheckRef(as)
}

func textopt(opts map[string]any, key string) string {
	text, _ := opts[key].(string)
	return text
}
