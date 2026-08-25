package station_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	station "github.com/voxgig/station/go/station"
)

// A station.json whose ROOT is not an object must fail open() with
// station_config_invalid, the way the canonical library and every other
// port do. It did not: LoadConfigOrder returned a nil config for a
// non-map root, and New() skips validation when the config is nil, so
// `[1,2,3]` opened a working Station with no error at all.
func TestConfigRootMustBeAnObject(t *testing.T) {
	for _, body := range []string{"[1,2,3]", `"a string"`, "42", "true", "null"} {
		dir := t.TempDir()
		if err := os.WriteFile(
			filepath.Join(dir, "station.json"), []byte(body), 0o644); nil != err {
			t.Fatal(err)
		}
		st, err := station.New(&station.Options{Folder: dir})
		if nil == err {
			t.Fatalf("root %s was accepted; station=%v, want station_config_invalid",
				body, nil != st)
		}
		if !strings.Contains(err.Error(), "station_config_invalid") {
			t.Fatalf("root %s: err = %v, want station_config_invalid", body, err)
		}
	}
}

// The declaration-order machinery had NO test that would catch its
// removal: every `merged` entry in the corpus happens to have
// alphabetically-ordered keys, so sorted == declared for all of them and
// `order = nil` at the top of namesInOrder left the whole suite green.
// This pins it on keys where the two genuinely differ.
func TestDeclarationOrderIsNotSortedOrder(t *testing.T) {
	dir := t.TempDir()
	// zeta before alpha: declared order and sorted order disagree, so a
	// port that quietly sorts cannot pass this.
	config := `{"station":1,"profiles":{"default":{"feature":{` +
		`"zeta":{"active":true},"alpha":{"active":true}}}}}`
	if err := os.WriteFile(
		filepath.Join(dir, "station.json"), []byte(config), 0o644); nil != err {
		t.Fatal(err)
	}
	st, err := station.New(&station.Options{Folder: dir})
	if nil != err {
		t.Fatalf("open: %v", err)
	}
	set, err := st.FeaturesOf("")
	if nil != err {
		t.Fatalf("FeaturesOf: %v", err)
	}
	if 2 != len(set.Declared) ||
		"zeta" != set.Declared[0] || "alpha" != set.Declared[1] {
		t.Fatalf("Declared = %v, want [zeta alpha] - the file's declaration "+
			"order, not the sorted order", set.Declared)
	}
}
