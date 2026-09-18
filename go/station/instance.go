package station

import "regexp"

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
