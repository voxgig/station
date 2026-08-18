// station.json loading and profile resolution (design §3.5).
//
// A port of typescript/src/profile.ts, which is canonical.
package station

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"

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
	// Plugin holds the per-plugin profile blocks, keyed by descriptor
	// slug: base, secret, resolve, policy.hosts, active.
	Plugin map[string]map[string]any
}

// ResolveProfile merges the base profile ('default') with the selected
// overlay: shallow-merge per plugin, EXCEPT secrets.providers which
// replaces wholesale (design §3.5, §5.2 - chain order decides which
// store wins, so a positional merge would be actively dangerous). The
// `profile` corpus section pins this.
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

	plugin := map[string]map[string]any{}
	for _, src := range []map[string]any{asMap(base["plugin"]), asMap(overlay["plugin"])} {
		for slug, raw := range src {
			entry := plugin[slug]
			if nil == entry {
				entry = map[string]any{}
				plugin[slug] = entry
			}
			for k, v := range asMap(raw) {
				entry[k] = v
			}
		}
	}

	// A configured secret name sekreto would reject is caught at profile
	// load, not first request (design §14 station_secret_name).
	for slug, entry := range plugin {
		if name, has := entry["secret"]; has && nil != name {
			if !sekreto.ValidName(name) {
				text, _ := name.(string)
				return nil, fail("station_secret_name",
					"profile \""+profileName+"\" plugin \""+slug+
						"\": secret name rejected by sekreto: "+strconv.Quote(text))
			}
		}
	}

	return &ResolvedProfile{Name: profileName, Providers: providers, Plugin: plugin}, nil
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
