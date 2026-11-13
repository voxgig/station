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

func TestAnUnpairedSurrogateEscapeIsRefused(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "station.json")
	body := `{ "station": 1, "profiles": { "x\ud800": {} } }`
	if err := os.WriteFile(file, []byte(body), 0o644); nil != err {
		t.Fatal(err)
	}
	_, err := station.LoadConfig(dir)
	want := "station_config_invalid: station.json at " + file +
		` has an unpaired surrogate escape in "x\ud800"`
	if nil == err || want != err.Error() {
		t.Fatalf("err = %v, want %s", err, want)
	}
}

// The corpus is JSON text, so it cannot carry these bytes.
func TestStationJsonIsReadAsUTF8AndRefusedWhenItIsNot(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "station.json")
	doc := func(note string) []byte {
		return []byte(`{ "station": 1, "profiles": { "default": { "sdk": ` +
			`{ "joplin": { "options": { "note": "` + note + `" } } } } } }`)
	}
	write := func(raw []byte) {
		if err := os.WriteFile(file, raw, 0o644); nil != err {
			t.Fatal(err)
		}
	}

	write(doc("\u00e9\U0001F600"))
	config, err := station.LoadConfig(dir)
	if nil != err {
		t.Fatal(err)
	}
	note := config["profiles"].(map[string]any)["default"].(map[string]any)["sdk"].(map[string]any)["joplin"].(map[string]any)["options"].(map[string]any)["note"]
	if "\u00e9\U0001F600" != note {
		t.Fatalf("raw UTF-8 reads as its characters: %q", note)
	}

	for _, bad := range []struct{ shape, bytes string }{
		{"stray", "\xe9"}, {"overlong", "\xc0\xaf"}, {"surrogate", "\xed\xa0\x80"},
		{"outofrange", "\xf4\x90\x80\x80"}, {"truncated", "\xf0\x9f\x98"},
	} {
		write(doc(bad.bytes))
		_, err = station.LoadConfig(dir)
		if want := "station_config_invalid: station.json at " + file + " is not UTF-8"; nil == err || want != err.Error() {
			t.Fatalf("%s: err = %v, want %s", bad.shape, err, want)
		}
	}

	write(append([]byte("\xef\xbb\xbf"), doc("ok")...))
	_, err = station.LoadConfig(dir)
	if nil == err || !strings.Contains(err.Error(), " is not valid JSON: ") {
		t.Fatalf("a byte order mark: %v", err)
	}
}

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
