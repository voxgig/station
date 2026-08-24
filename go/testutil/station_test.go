// RUN: make test
// RUN-SOME: cd testutil && go test -run 'TestStation/secretname'
//
// RUN-SOME names this NESTED module deliberately: the suite lives
// outside the published module (omni register 4.13), so the same
// command from the port root matches nothing and reports a green that
// ran no conformance at all.
//
// The station conformance suite: the pure-contract half of the design's
// §13 corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery (inject,
// order, event correlation) live in the integration suites against real
// generated SDKs; the corpus carries what a port can prove with no SDK
// present.

package station_test

import (
	"os"
	"path/filepath"
	"testing"

	omni "github.com/voxgig/omni/go"
	"github.com/voxgig/sekreto/go/sekreto"
	"github.com/voxgig/station/go/station"
)

// Find the shared spec directory by walking up from the working directory.
func specfile(t *testing.T, name string) string {
	t.Helper()

	dir, err := os.Getwd()
	if nil != err {
		t.Fatalf("station: no working directory: %v", err)
	}

	for i := 0; i < 8; i++ {
		cand := filepath.Join(dir, "spec", name)
		if _, err := os.Stat(cand); nil == err {
			return cand
		}
		dir = filepath.Dir(dir)
	}

	t.Fatalf("station: spec not found: %s", name)
	return ""
}

func entrymap(value any) map[string]any {
	out, _ := value.(map[string]any)
	return out
}

// Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
// serializer sees what the spec means.
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

// The subjects, adapted to the omni calling convention.
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
		slug, _ := args[0].(string)
		return station.PlaceholderFor(slug), nil
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

	// The §3.3 merge, and the whole of this port's profile contract.
	//
	// The `profile` section is NOT run: it pins the pre-Stage-1 `plugin`
	// grammar, which this port no longer speaks. It stays in the corpus
	// for the ports that have not crossed the rename yet and is deleted
	// when the last one does - see spec/README.md.
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

	ERRORS = omni.Subject(func(args ...any) (any, error) {
		code, _ := args[0].(string)
		return station.IsKnownCode(code), nil
	})
)

func TestStation(t *testing.T) {
	runner, err := omni.MakeRunner(specfile(t, "station.json"), nil)
	if nil != err {
		t.Fatalf("station: cannot make runner: %v", err)
	}

	R, err := runner("station", nil)
	if nil != err {
		t.Fatalf("station: cannot resolve spec: %v", err)
	}

	groups := []struct {
		name    string
		subject omni.Subject
	}{
		{"secretname", SECRETNAME},
		{"placeholder", PLACEHOLDER},
		{"descriptor", DESCRIPTOR},
		{"descriptorwarnings", DESCRIPTORWARNINGS},
		{"canonical", CANONICAL},
		{"instance", INSTANCE},
		{"errors", ERRORS},
	}

	for _, group := range groups {
		t.Run(group.name, func(t *testing.T) {
			if err := R.RunSet(R.Set(group.name), group.subject); nil != err {
				t.Fatal(err)
			}
		})
	}
}
