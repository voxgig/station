// station.json loading and profile resolution (design §3.5).
//
// A port of typescript/src/profile.ts, which is canonical.
package station

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/voxgig/sekreto/go/sekreto"
)

// FindConfigFile looks for station.json from `from` (default: the working
// directory) upward to the repo root, then ~/.voxgig/station.json (design
// §3.5). A repo root is where .git lives; with no repo the walk stops at
// the filesystem root. Empty string when nothing is found.
func FindConfigFile(from string) string {
	if "" == from {
		from, _ = os.Getwd()
	}
	dir, err := filepath.Abs(from)
	if nil != err {
		dir = from
	}
	for {
		candidate := filepath.Join(dir, "station.json")
		if _, err := os.Stat(candidate); nil == err {
			return candidate
		}
		_, repoErr := os.Stat(filepath.Join(dir, ".git"))
		atRepoRoot := nil == repoErr
		parent := filepath.Dir(dir)
		if atRepoRoot || parent == dir {
			break
		}
		dir = parent
	}
	home, err := os.UserHomeDir()
	if nil == err {
		candidate := filepath.Join(home, ".voxgig", "station.json")
		if _, err := os.Stat(candidate); nil == err {
			return candidate
		}
	}
	return ""
}

// LoadConfig reads the nearest station.json. nil (no error) when there is
// no config file at all.
func LoadConfig(from string) (map[string]any, error) {
	file := FindConfigFile(from)
	if "" == file {
		return nil, nil
	}
	text, err := os.ReadFile(file)
	if nil != err {
		return nil, err
	}
	var config map[string]any
	if err := json.Unmarshal(text, &config); nil != err {
		return nil, err
	}
	return config, nil
}

// SelectProfile picks the profile name: the Open() option, else
// VOXGIG_STATION_PROFILE, else 'default' (design §3.5 - env vars rank
// above station.json but below Open() opts; profile NAME selection
// follows the same order with Open() opts winning).
func SelectProfile(optProfile string) string {
	if "" != optProfile {
		return optProfile
	}
	if env := os.Getenv("VOXGIG_STATION_PROFILE"); "" != env {
		return env
	}
	return "default"
}

// ResolvedProfile is the merged view a Station runs on.
type ResolvedProfile struct {
	Name string
	// Providers is the sekreto ProviderSpec chain, verbatim JSON shapes
	// (design §5.2 - station neither extends nor validates it).
	Providers []any
	// Api holds the api-level defaults in effect for this profile, keyed
	// by api slug. A REPORT, not an input to the instance merge below -
	// collapsing each namespace first and composing at the end is the
	// exact algorithm §3.3 forbids.
	Api map[string]map[string]any
	// Sdk holds the resolved instances, keyed by REF (`api$tag`, or a
	// bare `api` for the untagged one). An api block declares no
	// instance of its own (§3.1), so it never creates an entry here.
	Sdk map[string]map[string]any
}

// blockDefaults is the one table applied AFTER the merge, never before
// (§3.3, §4.2). `active` is the key carrying that timing rule.
func blockDefaults() map[string]any {
	return map[string]any{"active": true, "feature": map[string]any{}}
}

// MergeSensitive names the block key that must not be materialized
// before the profile merge.
var MergeSensitive = []string{"active"}

// RefApi returns the api half of a ref: the substring before the first
// `$`. An untagged ref IS an api slug (§3.4).
//
// LEXICAL, and that is the point: under the old free-form identity which
// api an instance used was itself a merged value, so a port that got the
// phasing wrong silently picked another api's defaults.
func RefApi(ref string) string {
	if at := strings.Index(ref, "$"); -1 != at {
		return ref[:at]
	}
	return ref
}

// shallow merges per key, left to right - each source over the one
// before it. An overlay's `policy` REPLACES the base's entirely rather
// than merging `hosts` into it; an allowlist that widens because two
// precedence levels merged is the failure this rule prevents.
func shallow(sources ...map[string]any) map[string]any {
	out := map[string]any{}
	for _, src := range sources {
		for k, v := range src {
			out[k] = v
		}
	}
	return out
}

func mergedKeys(maps ...map[string]any) []string {
	seen := map[string]bool{}
	for _, m := range maps {
		for k := range m {
			seen[k] = true
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ResolveProfile merges the base profile ('default') with the selected
// overlay.
//
// §3.3's total order for the two block levels, lowest precedence first:
//
//	base.api[<api>] ⊕ base.sdk[<ref>] ⊕ overlay.api[<api>] ⊕ overlay.sdk[<ref>]
//
// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
// LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
// namespace, then put instance over api" - that lets every instance
// value beat every api value, so a production `api.stripe.policy` would
// fail to override a default profile's `sdk.stripe$test.policy`,
// silently keeping the wider allowlist in production.
//
// secrets.providers replaces wholesale, never merges (§3.5, §5.2 - chain
// order decides which store wins, so a positional merge would be
// actively dangerous).
func ResolveProfile(config map[string]any, profileName string) (*ResolvedProfile, error) {
	profiles := asMap(config["profiles"])
	base := asMap(profiles["default"])
	overlay := map[string]any{}
	if "default" != profileName {
		overlay = asMap(profiles[profileName])
	}

	providers := providersOf(overlay)
	if nil == providers {
		providers = providersOf(base)
	}
	if nil == providers {
		providers = []any{map[string]any{"kind": "env"}}
	}

	baseApi := asMap(base["api"])
	overApi := asMap(overlay["api"])
	baseSdk := asMap(base["sdk"])
	overSdk := asMap(overlay["sdk"])

	api := map[string]map[string]any{}
	for _, slug := range mergedKeys(baseApi, overApi) {
		api[slug] = shallow(asMap(baseApi[slug]), asMap(overApi[slug]))
	}

	sdk := map[string]map[string]any{}
	for _, ref := range mergedKeys(baseSdk, overSdk) {
		a := RefApi(ref)
		merged := shallow(
			asMap(baseApi[a]), asMap(baseSdk[ref]),
			asMap(overApi[a]), asMap(overSdk[ref]),
		)

		// Defaults are applied ONCE, to the fully merged instance. Had
		// the overlay block carried a synthesized `active` into the
		// merge, a one-key environment override would silently re-enable
		// an integration the base declared inactive.
		for k, v := range blockDefaults() {
			if _, has := merged[k]; !has {
				merged[k] = v
			}
		}

		sdk[ref] = merged
	}

	if err := checkSecrets(sdk, profileName); nil != err {
		return nil, err
	}

	return &ResolvedProfile{
		Name: profileName, Providers: providers, Api: api, Sdk: sdk,
	}, nil
}

// checkSecrets catches a configured secret name sekreto would reject at
// profile load, not first request (§14 station_secret_name) - and then
// checks the DERIVED names for uniqueness, because envtoken is LOSSY.
//
// It collapses any run of non-alphanumerics to `_`, so `stripe$test` and
// an untagged instance of a `stripe-test` api both derive
// `stripe_test.apikey` and would silently share one credential.
//
// Two instances that EXPLICITLY name one secret are not a collision -
// that is the shared-key case the api-level `secret` exists for.
func checkSecrets(sdk map[string]map[string]any, profileName string) error {
	refs := make([]string, 0, len(sdk))
	for ref := range sdk {
		refs = append(refs, ref)
	}
	sort.Strings(refs)

	for _, ref := range refs {
		if name, has := sdk[ref]["secret"]; has && nil != name {
			if !sekreto.ValidName(name) {
				text, _ := name.(string)
				return fail("station_secret_name",
					"profile \""+profileName+"\" sdk \""+ref+
						"\": secret name rejected by sekreto: "+strconv.Quote(text))
			}
		}
	}

	type holder struct {
		ref     string
		derived bool
	}
	seen := map[string]holder{}
	for _, ref := range refs {
		written, _ := sdk[ref]["secret"].(string)
		derived := "" == written
		name := written
		if derived {
			name = SecretnameDefault(ref)
		}

		prior, has := seen[name]
		if has && (derived || prior.derived) {
			return fail("station_secret_collision",
				"profile \""+profileName+"\": instances \""+prior.ref+
					"\" and \""+ref+"\" both resolve to secret name \""+name+
					"\", so they would share one credential; name it explicitly "+
					"on each, or at the api level to share it deliberately (§5.1)")
		}
		if !has {
			seen[name] = holder{ref: ref, derived: derived}
		}
	}
	return nil
}

func providersOf(profile map[string]any) []any {
	secrets := asMap(profile["secrets"])
	if nil == secrets {
		return nil
	}
	if providers, is := secrets["providers"].([]any); is {
		return providers
	}
	return nil
}
