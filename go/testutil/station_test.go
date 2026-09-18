package station_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"testing"

	omni "github.com/voxgig/omni/go"
	"github.com/voxgig/sekreto/go/sekreto"
	"github.com/voxgig/station/go/station"
)

// Find the shared spec directory by walking up from the working directory.
func findspec(name string) (string, error) {
	dir, err := os.Getwd()
	if nil != err {
		return "", err
	}

	for i := 0; i < 8; i++ {
		cand := filepath.Join(dir, "spec", name)
		if _, err := os.Stat(cand); nil == err {
			return cand, nil
		}
		dir = filepath.Dir(dir)
	}

	return "", os.ErrNotExist
}

func specfile(t *testing.T, name string) string {
	t.Helper()
	file, err := findspec(name)
	if nil != err {
		t.Fatalf("station: spec not found: %s: %v", name, err)
	}
	return file
}

func entrymap(value any) map[string]any {
	out, _ := value.(map[string]any)
	return out
}

// Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
// subject sees what the spec means.
func denull(value any) any {
	switch v := value.(type) {
	case string:
		if omni.NULLMARK == v {
			return nil
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = denull(item)
		}
		return out
	case map[string]any:
		out := map[string]any{}
		for k, item := range v {
			out[k] = denull(item)
		}
		return out
	}
	return value
}

func denullmap(value any) map[string]any {
	out, _ := denull(value).(map[string]any)
	return out
}

var (
	orderOnce  sync.Once
	orderIndex = map[string][]string{}
	orderErr   error
)

func mergedOrder(in any) ([]string, bool) {
	orderOnce.Do(func() {
		file, err := findspec("station.json")
		if nil != err {
			orderErr = err
			return
		}
		text, err := os.ReadFile(file)
		if nil != err {
			orderErr = err
			return
		}
		parsed, order, err := station.ParseOrdered(text)
		if nil != err {
			orderErr = err
			return
		}
		set, _ := getpath(parsed, "primary", "station", "feature", "set").([]any)
		setorder := order.At("primary", "station", "feature", "set")
		for i, raw := range set {
			entry, is := raw.(map[string]any)
			if !is {
				continue
			}
			if _, has := entry["in"]; !has {
				continue
			}
			key := station.CanonicalSerialize(entry["in"])
			orderIndex[key] = setorder.Item(i).At("in", "merged").Keys()
		}
	})
	if nil != orderErr {
		return nil, false
	}
	order, has := orderIndex[station.CanonicalSerialize(in)]
	return order, has
}

func errtext(err error) string {
	if nil == err {
		return "none"
	}
	return err.Error()
}

func getpath(node any, path ...string) any {
	at := node
	for _, key := range path {
		asmap, is := at.(map[string]any)
		if !is {
			return nil
		}
		at = asmap[key]
	}
	return at
}

// --- the subjects, adapted to the omni calling convention ---

var (
	SECRETNAME = omni.Subject(func(args ...any) (any, error) {
		entry := entrymap(args[0])
		slug := entry["slug"]
		secretname := ""
		if text, is := slug.(string); is {
			secretname = station.SecretnameDefault(text)
		}
		envkey, err := sekreto.EnvKey(secretname, "")
		if nil != err {
			return nil, err
		}
		return map[string]any{
			"envtoken":   station.Envtoken(slug),
			"secretname": secretname,
			"envkey":     envkey,
		}, nil
	})

	PLACEHOLDER = omni.Subject(func(args ...any) (any, error) {
		name, _ := args[0].(string)
		return station.PlaceholderFor(name), nil
	})

	DESCRIPTOR = omni.Subject(func(args ...any) (any, error) {
		entry := entrymap(args[0])
		descriptor, _ := station.NormalizeDescriptor(
			entrymap(entry["config"]), entrymap(entry["feature"]))
		return descriptor, nil
	})

	DESCRIPTORWARNINGS = omni.Subject(func(args ...any) (any, error) {
		entry := entrymap(args[0])
		_, warnings := station.NormalizeDescriptor(
			entrymap(entry["config"]), entrymap(entry["feature"]))
		return len(warnings), nil
	})

	CANONICAL = omni.Subject(func(args ...any) (any, error) {
		return station.CanonicalSerialize(denull(args[0])), nil
	})

	CONFIG = omni.Subject(func(args ...any) (any, error) {
		return station.ValidateConfig(station.NormalizeConfig(denull(args[0])))
	})

	// The §3.3 merge, and the whole of this port's profile contract.
	INSTANCE = omni.Subject(func(args ...any) (any, error) {
		entry := entrymap(args[0])
		// A NULLMARK config (spec null) is no config at all.
		config := entrymap(entry["config"])
		profileName, _ := entry["profile"].(string)
		resolved, err := station.ResolveProfile(config, profileName)
		if nil != err {
			return nil, err
		}
		api := map[string]any{}
		for slug, one := range resolved.Api {
			api[slug] = one
		}
		sdk := map[string]any{}
		for ref, one := range resolved.Sdk {
			sdk[ref] = one
		}
		return map[string]any{
			"name":      resolved.Name,
			"providers": resolved.Providers,
			"api":       api,
			"sdk":       sdk,
		}, nil
	})

	// §6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
	// rather than driver-shaped even though it decides a registry key.
	INSTANCEREF = omni.Subject(func(args ...any) (any, error) {
		entry := entrymap(args[0])
		api, _ := entry["api"].(string)
		return station.InstanceRef(api, entrymap(entry["opts"]))
	})

	FEATURE = omni.Subject(func(args ...any) (any, error) {
		entry := entrymap(args[0])
		if raw, has := entry["merged"]; has && nil != raw && omni.NULLMARK != raw {
			merged := denullmap(raw)
			declared, found := mergedOrder(entry)
			if !found {
				return nil, errors.New("station: no authored key order for " +
					station.CanonicalSerialize(entry) + " (orderErr: " +
					errtext(orderErr) + ")")
			}
			ordered, err := station.ResolveOrder(merged, declared)
			if nil != err {
				return nil, err
			}
			if err := station.CheckPin(ordered); nil != err {
				return nil, err
			}
			return station.FeatureNames(ordered), nil
		}
		api, _ := entry["api"].(string)
		ref, _ := entry["ref"].(string)
		return station.MergeFeatures(station.FeatureSources(
			denullmap(entry["base"]), denullmap(entry["overlay"]), api, ref)), nil
	})

	ERRORS = omni.Subject(func(args ...any) (any, error) {
		code, _ := args[0].(string)
		return station.IsKnownCode(code), nil
	})
)

var DRIVERS = []struct {
	name    string
	subject omni.Subject
}{
	{"secretname", SECRETNAME},
	{"placeholder", PLACEHOLDER},
	{"descriptor", DESCRIPTOR},
	{"descriptorwarnings", DESCRIPTORWARNINGS},
	{"canonical", CANONICAL},
	{"config", CONFIG},
	{"instance", INSTANCE},
	{"instanceref", INSTANCEREF},
	{"feature", FEATURE},
	{"errors", ERRORS},
}

var PENDING = []struct {
	name   string
	reason string
}{}

func TestSectionsCovered(t *testing.T) {
	text, err := os.ReadFile(specfile(t, "station.json"))
	if nil != err {
		t.Fatalf("station: cannot read spec: %v", err)
	}
	var spec map[string]any
	if err := json.Unmarshal(text, &spec); nil != err {
		t.Fatalf("station: cannot parse spec: %v", err)
	}

	sections, is := getpath(spec, "primary", "station").(map[string]any)
	if !is {
		t.Fatal("station: spec has no primary.station sections")
	}

	present := []string{}
	for name := range sections {
		present = append(present, name)
	}
	sort.Strings(present)

	covered := []string{}
	for _, driver := range DRIVERS {
		covered = append(covered, driver.name)
	}
	for _, pending := range PENDING {
		covered = append(covered, pending.name)
	}
	sort.Strings(covered)

	if !reflect.DeepEqual(present, covered) {
		t.Fatalf("station: corpus sections not covered\n  present: %v\n  covered: %v",
			present, covered)
	}
}

func TestStation(t *testing.T) {
	runner, err := omni.MakeRunner(specfile(t, "station.json"), nil)
	if nil != err {
		t.Fatalf("station: cannot make runner: %v", err)
	}

	R, err := runner("station", nil)
	if nil != err {
		t.Fatalf("station: cannot resolve spec: %v", err)
	}

	for _, driver := range DRIVERS {
		t.Run(driver.name, func(t *testing.T) {
			set := R.Set(driver.name)
			if nil == set {
				t.Fatalf("station: corpus section missing: %s", driver.name)
			}
			if err := R.RunSet(set, driver.subject); nil != err {
				t.Fatal(err)
			}
		})
	}
}
