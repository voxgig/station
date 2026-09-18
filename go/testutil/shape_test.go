// RUN: make test
// RUN-SOME: cd testutil && go test -run 'TestShape'
//
// The shape artifact is DATA (design §4.3): `spec/config-shape.json` is
// the copy every port reads, and this port EMBEDS a mirror of it -
// go:embed in station/shape.go - because a Go module ships compiled and

package station_test

import (
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"strconv"
	"testing"

	"github.com/voxgig/station/go/station"
)

func TestShapeMirrorHasNotDrifted(t *testing.T) {
	text, err := os.ReadFile(specfile(t, "config-shape.json"))
	if nil != err {
		t.Fatalf("station: cannot read the shape: %v", err)
	}
	var spec any
	if err := json.Unmarshal(text, &spec); nil != err {
		t.Fatalf("station: cannot parse the shape: %v", err)
	}

	if !reflect.DeepEqual(spec, station.ConfigShape()) {
		t.Fatal("station: the embedded config shape has drifted from " +
			"spec/config-shape.json - run `make sync-shape`")
	}
}

// Every validate must get a FRESH DEEP COPY: struct's validator CONSUMES
// the spec it walks - it deletes satisfied `$ONE` branches as it goes -
// so handing it one parsed constant twice validates the second config
// against a spec the first already ate.
func TestShapeIsFreshEachCall(t *testing.T) {
	first := station.ConfigShape()
	second := station.ConfigShape()

	if !reflect.DeepEqual(first, second) {
		t.Fatal("station: two shape copies differ")
	}

	config := map[string]any{"station": 1, "profiles": map[string]any{}}
	for i := 0; i < 3; i++ {
		if _, err := station.ValidateConfig(
			station.NormalizeConfig(config)); nil != err {
			t.Fatalf("station: run %d of one valid config failed: %v", i, err)
		}
	}
}

func TestShapeBlockSpecsAreIdentical(t *testing.T) {
	shape, _ := station.ConfigShape().(map[string]any)
	profile := child(t, child(t, shape, "profiles"), "`$CHILD`")
	api := child(t, child(t, profile, "api"), "`$CHILD`")
	sdk := child(t, child(t, profile, "sdk"), "`$CHILD`")

	if !reflect.DeepEqual(api, sdk) {
		t.Fatal("station: the api and sdk block specs must be the same " +
			"grammar (§3.4)")
	}
}

func TestShapeMergeSensitiveNamesTheNonContainerDefaults(t *testing.T) {
	if !reflect.DeepEqual([]string{"active"}, station.MergeSensitive) {
		t.Fatalf("station: MergeSensitive is %v", station.MergeSensitive)
	}

	defaults := station.BlockDefaults()

	// Every merge-sensitive key has a default - naming a key that has
	// none would name nothing.
	for _, key := range station.MergeSensitive {
		if _, has := defaults[key]; !has {
			t.Fatalf("station: merge-sensitive %q has no block default", key)
		}
	}

	// ...and every default that is not a CONTAINER is merge-sensitive: a
	// container merges as empty whether or not it was materialized
	// early, a scalar does not.
	for key, make := range defaults {
		switch make().(type) {
		case map[string]any, []any:
			continue
		}
		found := false
		for _, one := range station.MergeSensitive {
			if one == key {
				found = true
			}
		}
		if !found {
			t.Fatalf("station: block default %q is a scalar and must be "+
				"merge-sensitive (§3.3)", key)
		}
	}
}

func TestShapeOpensOnlyTheFeatureEntries(t *testing.T) {
	open := []string{}
	var walk func(node any, path string)
	walk = func(node any, path string) {
		switch v := node.(type) {
		case map[string]any:
			for _, key := range sortedkeys(v) {
				if "`$OPEN`" == key {
					open = append(open, path)
				}
				walk(v[key], join(path, key))
			}
		case []any:
			for i, one := range v {
				walk(one, join(path, strconv.Itoa(i)))
			}
		}
	}
	walk(station.ConfigShape(), "")
	sort.Strings(open)

	want := []string{
		"profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`",
		"profiles.`$CHILD`.feature.`$CHILD`",
		"profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`",
	}
	if !reflect.DeepEqual(want, open) {
		t.Fatalf("station: `$OPEN` nodes are %v, want %v", open, want)
	}
}

func child(t *testing.T, node map[string]any, key string) map[string]any {
	t.Helper()
	out, is := node[key].(map[string]any)
	if !is {
		t.Fatalf("station: the shape has no map at %q", key)
	}
	return out
}

func sortedkeys(node map[string]any) []string {
	out := make([]string, 0, len(node))
	for key := range node {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}

func join(path string, key string) string {
	if "" == path {
		return key
	}
	return path + "." + key
}
