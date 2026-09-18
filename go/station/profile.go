// station.json loading and profile resolution (design §3.5).
//
// A port of typescript/src/profile.ts, which is canonical.
package station

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/voxgig/sekreto/go/sekreto"
)

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
	config, _, err := LoadConfigOrder(from)
	return config, err
}

func LoadConfigOrder(from string) (map[string]any, *Order, error) {
	file := FindConfigFile(from)
	if "" == file {
		return nil, nil, nil
	}
	text, err := os.ReadFile(file)
	if nil != err {
		return nil, nil, err
	}
	// A file that is not JSON is a config error, not a raw parse error
	// escaping Open(): the reader found station.json and could not use
	// it, which is exactly what station_config_invalid exists to say.
	parsed, order, err := ParseOrdered(text)
	if nil != err {
		return nil, nil, fail("station_config_invalid",
			"station.json at "+file+" is not valid JSON: "+err.Error())
	}
	config, is := parsed.(map[string]any)
	if !is {
		if _, err := ValidateConfig(NormalizeConfig(parsed)); nil != err {
			return nil, nil, err
		}
		return nil, order, nil
	}
	return config, order, nil
}

func ConfigScope(from string) string {
	file := FindConfigFile(from)
	if "" == file {
		return "none"
	}
	home, err := os.UserHomeDir()
	if nil == err && file == filepath.Join(home, ".voxgig", "station.json") {
		return "user"
	}
	return "repo"
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
	Api       map[string]map[string]any
	Sdk       map[string]map[string]any
}

func RefApi(ref string) string {
	if at := strings.Index(ref, "$"); -1 != at {
		return ref[:at]
	}
	return ref
}

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
		defaults := BlockDefaults()
		for _, k := range defaultkeys(defaults) {
			if _, has := merged[k]; !has {
				merged[k] = defaults[k]()
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
