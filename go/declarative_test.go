// RUN: make test
// RUN-SOME: go test -run 'TestFactory|TestDeclarative|TestFeatures|TestWarm'
//
// The declarative front door (design §6) and the §8 feature machinery,
// for the parts the JSON corpus cannot express: they need a factory, a
// constructor and a live registry, and the corpus deliberately carries
// only what a port can prove with no SDK present.
//
// The fake factory below is the smallest thing that behaves like a
// generated package: a `config` constant beside a constructor that
// builds a client and calls station.Bind. That IS the §6.2 contract - a
// factory is a constructor PLUS the SDK's static config - so a fake
// missing either half would not be a fake of anything.

package station_test

import (
	"strings"
	"testing"

	"github.com/voxgig/station/go/station"
)

// --- a miniature generated package ---

// fakeSDKConfig is fakeConfig with a declared feature set: `feature` in
// an SDK's embedded config is name -> {options: <typed defaults>}, and
// §8.5 validates a station.json feature entry against exactly that.
func fakeSDKConfig(slug string, features map[string]any) map[string]any {
	config := fakeConfig(slug, "FakeSDK", true)
	fmap := map[string]any{"station": map[string]any{}, "test": map[string]any{}}
	for name, def := range features {
		fmap[name] = def
	}
	config["feature"] = fmap
	return config
}

// fakeFactory is what a generated package would register in its
// func init(): the constructor, and the config beside it.
func fakeFactory(config map[string]any) station.Factory {
	return station.Factory{
		Config: config,
		Construct: func(options map[string]any) any {
			client := &fakeClient{
				mode: "live", fetcher: okResponse(), options: options,
			}
			if _, has := options["apikey"]; !has {
				options["apikey"] = ""
			}

			fmap, _ := options["feature"].(map[string]any)
			fopts, _ := fmap["station"].(map[string]any)

			inner := client.fetcher
			station.Bind(&station.BindSpec{
				Client:       client,
				Config:       config,
				SDKOptions:   options,
				FeatureOpts:  fopts,
				FeatureNames: []string{"station"},
				Mode:         func() string { return client.mode },
				Fetch: func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
					return inner(opctx, fullurl, fetchdef)
				},
				SetFetch: func(next station.TransportFunc) { client.fetcher = next },
			})
			return client
		},
	}
}

func provideFake(t *testing.T, slug string, features map[string]any) {
	t.Helper()
	station.ResetFactories()
	t.Cleanup(station.ResetFactories)
	station.Provide(slug, fakeFactory(fakeSDKConfig(slug, features)))
}

func declarative(t *testing.T, profiles map[string]any) *station.Station {
	t.Helper()
	st, err := station.New(&station.Options{
		NoConfig: true,
		Config:   map[string]any{"station": 1, "profiles": profiles},
	})
	if nil != err {
		t.Fatalf("station: %v", err)
	}
	return st
}

func expectCode(t *testing.T, code string, err error) *station.Error {
	t.Helper()
	serr, is := err.(*station.Error)
	if !is || code != serr.Code {
		t.Fatalf("expected %s, got %v", code, err)
	}
	return serr
}

// --- the factory table (design §6.2) ---

func TestFactoryTableIsIdempotentAndConflictChecked(t *testing.T) {
	station.ResetFactories()
	defer station.ResetFactories()

	factory := fakeFactory(fakeSDKConfig("fakepad", nil))
	entry := station.Provide("fakepad", factory)

	// The descriptor is normalized AT PROVIDE TIME - that is what makes
	// check() able to validate without constructing (§6.2).
	if "fakepad" != entry.Descriptor["slug"] {
		t.Fatalf("descriptor not normalized at provide time: %v", entry.Descriptor)
	}

	// Registering the SAME pair twice is ordinary: module
	// self-registration plus an explicit Provide.
	if entry != station.Provide("fakepad", factory) {
		t.Fatal("provide must be idempotent for one pair")
	}
	if entry != station.FactoryFor("fakepad") {
		t.Fatal("factoryFor must return the registered entry")
	}
	if 1 != len(station.Provided()) || "fakepad" != station.Provided()[0] {
		t.Fatalf("provided(): %v", station.Provided())
	}

	// A DIFFERENT factory for one api is never resolved silently.
	expectPanicCode(t, "station_factory_conflict", func() {
		station.Provide("fakepad", fakeFactory(fakeSDKConfig("fakepad", nil)))
	})

	station.ResetFactories()
	if 0 != len(station.Provided()) {
		t.Fatal("resetFactories must empty the table")
	}
}

// --- sdk / create / instances (design §6.1, §6.5) ---

func TestDeclarativeSDKCachesAndCreateDoesNot(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{"fakepad": map[string]any{}},
		},
	})

	first, err := st.SDK("fakepad")
	if nil != err {
		t.Fatal(err)
	}
	second, err := st.SDK("fakepad")
	if nil != err {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("sdk() must cache by name")
	}

	// create() is uncached and registers under an auto-assigned tag, so
	// a second one does not fail station_bound_twice.
	third, err := st.Create("fakepad", nil)
	if nil != err {
		t.Fatal(err)
	}
	fourth, err := st.Create("fakepad", nil)
	if nil != err {
		t.Fatal(err)
	}
	if third == fourth || third == first {
		t.Fatal("create() must return a distinct client each time")
	}

	// EXHAUSTIVE: the auto-tagged clients are not collapsed away.
	names := []string{}
	for _, entry := range st.Plugins() {
		names = append(names, entry.Name)
	}
	want := "fakepad, fakepad$1, fakepad$2"
	if want != strings.Join(names, ", ") {
		t.Fatalf("plugins(): %v, want %s", names, want)
	}

	// An auto-tagged client is an ORDINARY instance: its placeholder is
	// its own, and its secret name is the DECLARED instance's, so every
	// per-request client shares one broker cache entry (§5.3).
	for _, entry := range st.Plugins() {
		if station.PlaceholderFor(entry.Name) != "[station:"+entry.Name+"]" {
			t.Fatalf("placeholder: %v", entry.Name)
		}
		if "fakepad.apikey" != entry.Secretname {
			t.Fatalf("secretname for %s: %q", entry.Name, entry.Secretname)
		}
	}
}

func TestDeclarativeAutotagSkipsDeclaredNames(t *testing.T) {
	provideFake(t, "fakepad", nil)
	// THE REGISTRY ALONE IS NOT ENOUGH: `fakepad$1` is declared and not
	// yet built, so the registry says false and the tag must still be
	// taken as reserved.
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad":   map[string]any{},
				"fakepad$1": map[string]any{"secret": "one.apikey"},
			},
		},
	})

	if "fakepad$2" != st.Autotag("fakepad") {
		t.Fatalf("autotag took a declared name: %s", st.Autotag("fakepad"))
	}
}

func TestDeclarativeUnknownAndInactiveInstances(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad":       map[string]any{},
				"fakepad$stale": map[string]any{"active": false},
			},
		},
	})

	_, err := st.SDK("fakepad$nope")
	serr := expectCode(t, "station_no_instance", err)
	if !strings.Contains(serr.Message, "fakepad$stale") {
		t.Fatalf("the error must name the declared instances: %v", serr)
	}

	_, err = st.SDK("fakepad$stale")
	expectCode(t, "station_instance_inactive", err)

	// ...and an inactive instance stays VISIBLE, which is the whole
	// point of `active: false` over deleting the block.
	rows := st.Instances()
	if 2 != len(rows) || rows[1].Active || !rows[0].Active {
		t.Fatalf("instances(): %+v", rows)
	}
	if rows[0].Live {
		t.Fatal("a declared instance is not live until it is built")
	}
}

// --- §5.4: the loader divergence, stated rather than implied ---

func TestDeclarativePackageIsNotHonouredHere(t *testing.T) {
	station.ResetFactories()
	defer station.ResetFactories()

	st := declarative(t, map[string]any{
		"default": map[string]any{
			"api": map[string]any{
				"fakepad": map[string]any{"package": "github.com/acme/fakepad-sdk"},
			},
			"sdk": map[string]any{"fakepad": map[string]any{}},
		},
	})

	// One warning event per api, at open, once - not an error.
	warns := 0
	for _, event := range filterEvents(st.Events(), "station") {
		if warn, _ := event.Meta["warn"].(string); strings.Contains(warn, "`package`") {
			warns++
			if "fakepad" != event.API {
				t.Fatalf("the warning must name the api: %+v", event)
			}
		}
	}
	if 1 != warns {
		t.Fatalf("expected one `package` warning, got %d", warns)
	}

	// ...and the no-factory error names ONLY the remedies this port
	// offers. A message telling a Go user to set `api.<slug>.package`
	// would send them down a road with no end.
	_, err := st.SDK("fakepad")
	serr := expectCode(t, "station_no_factory", err)
	if !strings.Contains(serr.Message, "station.Provide") ||
		!strings.Contains(serr.Message, "self-registers") {
		t.Fatalf("the remedies must be this port's: %v", serr)
	}
	if strings.Contains(serr.Message, "so the loader can import it") {
		t.Fatalf("the message offers a loader this port does not have: %v", serr)
	}

	// Load() is present and inert, and Options{Load} is accepted.
	if err := st.Load(); nil != err {
		t.Fatalf("load() must be inert here: %v", err)
	}
	no := false
	if _, err := station.New(&station.Options{NoConfig: true, Load: &no}); nil != err {
		t.Fatalf("Options.Load must be accepted: %v", err)
	}
}

// --- §8.5: the descriptor-derived checker, at build ---

func TestDeclarativeFeatureCheckAtBuild(t *testing.T) {
	provideFake(t, "fakepad", map[string]any{
		"retry": map[string]any{"options": map[string]any{"max": 1, "wait": 100}},
	})

	// An unknown option is THE CASE THAT ACTUALLY BITES: `retry.retires`
	// is accepted and silently ignored by the SDK, because its own
	// feature spec is `$OPEN` per feature.
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"feature": map[string]any{
						"retry": map[string]any{"retires": 5},
					},
				},
			},
		},
	})
	_, err := st.SDK("fakepad")
	serr := expectCode(t, "station_feature_option", err)
	if !strings.Contains(serr.Message, "declares no option \"retires\"") {
		t.Fatalf("message: %v", serr)
	}

	// A kind mismatch against the declared default.
	st = declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"feature": map[string]any{
						"retry": map[string]any{"max": "lots"},
					},
				},
			},
		},
	})
	_, err = st.SDK("fakepad")
	serr = expectCode(t, "station_feature_option", err)
	if !strings.Contains(serr.Message, "expects number, but found string") {
		t.Fatalf("message: %v", serr)
	}

	// A feature the SDK does not declare at all.
	st = declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"feature": map[string]any{"nosuch": map[string]any{}},
				},
			},
		},
	})
	_, err = st.SDK("fakepad")
	serr = expectCode(t, "station_feature_unknown", err)
	if !strings.Contains(serr.Message, "it declares [retry, station, test]") {
		t.Fatalf("message: %v", serr)
	}

	// ...and a config the SDK does declare builds, with the option
	// riding the constructor's feature map.
	st = declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"feature": map[string]any{
						"retry": map[string]any{"max": 3},
					},
				},
			},
		},
	})
	if _, err := st.SDK("fakepad"); nil != err {
		t.Fatalf("a declared option must build: %v", err)
	}
}

// --- §8.7: the merged feature set, with provenance ---

func TestFeaturesOfMergesThreeLevelsWithProvenance(t *testing.T) {
	provideFake(t, "fakepad", map[string]any{
		"retry": map[string]any{"options": map[string]any{"max": 1, "wait": 100}},
	})
	st, err := station.New(&station.Options{
		Profile: "prod",
		Config: map[string]any{
			"station": 1,
			"profiles": map[string]any{
				"default": map[string]any{
					"feature": map[string]any{
						"retry": map[string]any{"max": 1, "wait": 100},
					},
					"api": map[string]any{
						"fakepad": map[string]any{
							"feature": map[string]any{"retry": map[string]any{"max": 2}},
						},
					},
					"sdk": map[string]any{
						"fakepad$eu": map[string]any{
							"feature": map[string]any{"retry": map[string]any{"max": 3}},
						},
					},
				},
				"prod": map[string]any{
					"feature": map[string]any{"retry": map[string]any{"max": 4}},
				},
			},
		},
	})
	if nil != err {
		t.Fatal(err)
	}

	resolved, err := st.FeaturesOf("fakepad$eu")
	if nil != err {
		t.Fatal(err)
	}

	// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY: the prod profile's
	// own feature block beats the default profile's instance block.
	entry, _ := resolved.Merged["retry"].(map[string]any)
	if 4.0 != toFloat(entry["max"]) || 100.0 != toFloat(entry["wait"]) {
		t.Fatalf("merged: %v", entry)
	}
	if "prod.feature" != resolved.From["retry"]["max"] {
		t.Fatalf("provenance for max: %v", resolved.From["retry"])
	}
	if "default.feature" != resolved.From["retry"]["wait"] {
		t.Fatalf("provenance for wait: %v", resolved.From["retry"])
	}

	// THE IMPLICIT STATION ROW is in `ordered` and never in `merged`.
	if _, has := resolved.Merged["station"]; has {
		t.Fatal("`station` must never be in the merged map")
	}
	if "retry, station" != strings.Join(resolved.Ordered, ", ") {
		t.Fatalf("ordered: %v", resolved.Ordered)
	}
}

func TestFeaturesOfComposesThePolicyBudget(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"feature": map[string]any{
						"ratelimit": map[string]any{"jitter": true},
					},
					"policy": map[string]any{
						"budget": map[string]any{"rps": 5, "concurrency": 2},
					},
				},
			},
		},
	})

	resolved, err := st.FeaturesOf("fakepad")
	if nil != err {
		t.Fatal(err)
	}
	entry, _ := resolved.Merged["ratelimit"].(map[string]any)

	// POLICY WINS on exactly the keys it sets - it is enforcement, not a
	// default - and other tuning keys survive beside it.
	if true != entry["active"] || 5.0 != toFloat(entry["rate"]) ||
		2.0 != toFloat(entry["burst"]) || true != entry["jitter"] {
		t.Fatalf("composed ratelimit: %v", entry)
	}
	if "policy.budget" != resolved.From["ratelimit"]["rate"] ||
		"policy.budget" != resolved.From["ratelimit"]["burst"] {
		t.Fatalf("provenance: %v", resolved.From["ratelimit"])
	}

	// ...and it reaches §8.5, so a budget on an SDK with no ratelimit
	// feature is station_feature_unknown rather than a setting that
	// quietly did nothing.
	if _, err := st.SDK("fakepad"); nil == err {
		t.Fatal("expected the budget to reach the §8.5 checker")
	} else {
		expectCode(t, "station_feature_unknown", err)
	}
}

func TestFeaturesFleetViewNarrowsRowsToTheFeature(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"feature": map[string]any{"debug": map[string]any{"level": 3}},
				},
				"fakepad$quiet": map[string]any{},
			},
		},
	})

	all, err := st.Features(nil)
	if nil != err {
		t.Fatal(err)
	}
	if 2 != len(all) {
		t.Fatalf("expected a row per declared instance: %d", len(all))
	}

	// The `feature` filter narrows the ROWS, not the instances: "where
	// is debug on, and with what".
	rows, err := st.Features(&station.FeatureFilter{Feature: "debug"})
	if nil != err {
		t.Fatal(err)
	}
	if 1 != len(rows) || "fakepad" != rows[0].Instance {
		t.Fatalf("feature filter: %+v", rows)
	}
	if 1 != len(rows[0].Merged) || 1 != len(rows[0].Ordered) {
		t.Fatalf("the row must be narrowed to the feature: %+v", rows[0])
	}

	// The string shorthand matches an instance OR an api.
	loose, err := st.Features(station.LooseFilter("fakepad$quiet"))
	if nil != err {
		t.Fatal(err)
	}
	if 1 != len(loose) || "fakepad$quiet" != loose[0].Instance {
		t.Fatalf("loose filter: %+v", loose)
	}
}

// --- §6.6 / §5.5: check and warm ---

func TestCheckReportsEveryActiveInstance(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad":     map[string]any{},
				"fakepad$off": map[string]any{"active": false},
				"fakepad$bad": map[string]any{"feature": map[string]any{"nosuch": map[string]any{}}},
				"nofactory$x": map[string]any{},
			},
		},
	})

	result := st.Check()
	if 1 != len(result.OK) || "fakepad" != result.OK[0] {
		t.Fatalf("ok: %v", result.OK)
	}
	byname := map[string]string{}
	for _, one := range result.Failed {
		byname[one.Name] = one.Code
	}
	if "station_feature_unknown" != byname["fakepad$bad"] {
		t.Fatalf("failed: %+v", result.Failed)
	}
	if "station_no_factory" != byname["nofactory$x"] {
		t.Fatalf("failed: %+v", result.Failed)
	}
	if _, has := byname["fakepad$off"]; has {
		t.Fatal("check() must skip inactive instances")
	}
}

func TestWarmDedupesBySecretNameAndMissesTypos(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st, err := station.New(&station.Options{
		Config: map[string]any{
			"station": 1,
			"profiles": map[string]any{
				"default": map[string]any{
					"secrets": map[string]any{"providers": []any{
						map[string]any{"kind": "memory", "values": map[string]string{
							"SHARED_APIKEY": "k",
						}},
					}},
					"api": map[string]any{
						"fakepad": map[string]any{"secret": "shared.apikey"},
					},
					"sdk": map[string]any{
						"fakepad$one": map[string]any{},
						"fakepad$two": map[string]any{},
						"fakepad$gap": map[string]any{"secret": "missing.apikey"},
					},
				},
			},
		},
	})
	if nil != err {
		t.Fatal(err)
	}

	result := st.Warm(nil)
	if "fakepad$one, fakepad$two" != strings.Join(result.Warmed, ", ") {
		t.Fatalf("warmed: %v", result.Warmed)
	}
	if "fakepad$gap" != strings.Join(result.Missed, ", ") {
		t.Fatalf("missed: %v", result.Missed)
	}

	// A NAME NOBODY DECLARED OR REGISTERED IS A MISS, NOT A LOOKUP: a
	// typo must never derive a secret name off a shared api-level
	// credential and report itself warmed.
	result = st.Warm([]string{"fakepad$onee"})
	if 0 != len(result.Warmed) || "fakepad$onee" != strings.Join(result.Missed, ", ") {
		t.Fatalf("a typo must miss: %+v", result)
	}
}

// --- §6.3: the review boundary ---

func TestRepoScopedReadsTheExplicitOptionFirst(t *testing.T) {
	st := declarative(t, map[string]any{})
	if !st.RepoScoped() {
		t.Fatal("an in-code config is repo-scoped by construction")
	}

	// EXPLICIT WINS. Inferring before reading the option is a real
	// precedence bug: it makes RepoScoped=false unsettable for any
	// caller passing a config in code, which is every test of the rule.
	no := false
	st, err := station.New(&station.Options{
		RepoScoped: &no,
		Config:     map[string]any{"station": 1, "profiles": map[string]any{}},
	})
	if nil != err {
		t.Fatal(err)
	}
	if st.RepoScoped() {
		t.Fatal("an explicit RepoScoped must win over the inference")
	}

	if "none" != station.ConfigScope(t.TempDir()) {
		t.Fatalf("an empty tree has no config: %s", station.ConfigScope(t.TempDir()))
	}
}

// --- §4.2: normalize never mutates its input ---

func TestNormalizeConfigDoesNotMutateTheInput(t *testing.T) {
	block := map[string]any{}
	profile := map[string]any{"sdk": map[string]any{"solar": block}}
	raw := map[string]any{"profiles": map[string]any{"default": profile}}

	normalized, _ := station.NormalizeConfig(raw).(map[string]any)

	if _, has := raw["station"]; has {
		t.Fatal("the input grew a station key")
	}
	if _, has := profile["secrets"]; has {
		t.Fatal("the input profile grew a secrets key")
	}
	if _, has := block["active"]; has {
		t.Fatal("the input block grew an active key")
	}
	if 1 != normalized["station"] {
		t.Fatalf("the copy is missing the defaults: %v", normalized)
	}
}

// --- §7.1/§7.2: the registry is keyed by instance ---

func TestTwoInstancesOfOneApiAreDistinct(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad":      map[string]any{},
				"fakepad$test": map[string]any{},
			},
		},
	})

	if _, err := st.SDK("fakepad"); nil != err {
		t.Fatal(err)
	}
	if _, err := st.SDK("fakepad$test"); nil != err {
		t.Fatal(err)
	}

	entries := st.Plugins()
	if 2 != len(entries) {
		t.Fatalf("two clients of one api is the normal case now: %+v", entries)
	}
	// §5.1: the secret name is INSTANCE-derived, so the two do not
	// silently share one credential.
	if "fakepad.apikey" != entries[0].Secretname ||
		"fakepad_test.apikey" != entries[1].Secretname {
		t.Fatalf("secret names: %q %q", entries[0].Secretname, entries[1].Secretname)
	}
	// ...and each has its own placeholder, or the injection seam cannot
	// tell which credential a header wants.
	if station.PlaceholderFor(entries[0].Name) ==
		station.PlaceholderFor(entries[1].Name) {
		t.Fatal("two live instances of one api must have distinct placeholders")
	}
	// Both events carry the instance AND the api (§7.3's grouping).
	for _, event := range filterEvents(st.Events(), "construct") {
		if "" == event.Plugin || "fakepad" != event.API {
			t.Fatalf("construct event: %+v", event)
		}
	}
}

// --- §16: the policy allowlist is enforcement, applied at binding ---

func TestPolicyAllowlistReachesTheSDKOptions(t *testing.T) {
	provideFake(t, "fakepad", nil)
	st := declarative(t, map[string]any{
		"default": map[string]any{
			"sdk": map[string]any{
				"fakepad": map[string]any{
					"options": map[string]any{
						"allow": map[string]any{"op": "everything"},
					},
					"policy": map[string]any{
						"allow": map[string]any{
							"op":     []any{"find", "list"},
							"method": []any{"GET"},
						},
					},
				},
			},
		},
	})

	client, err := st.SDK("fakepad")
	if nil != err {
		t.Fatal(err)
	}
	fake, _ := client.(*fakeClient)
	if nil == fake {
		t.Fatal("expected the fake client")
	}

	// The options map the constructor was handed is the one Bind
	// mutated; read it back through the station's own view of the
	// instance rather than the client, which the fake does not keep.
	allow, _ := fake.options["allow"].(map[string]any)
	if "find,list" != allow["op"] || "GET" != allow["method"] {
		t.Fatalf("policy must win over the block's own options: %v", allow)
	}
}

// CheckPackage is the one piece of §6.3 that survives here: pure, and
// called by nothing this port runs - it exists so a Go-side tool can
// hold a shared station.json to the same rule the loading ports apply.
func TestCheckPackageTakesModuleNamesOnly(t *testing.T) {
	for _, good := range []string{
		"github.com/acme/stripe-sdk", "@acme-sdk/stripe", "stripe_sdk",
	} {
		if _, err := station.CheckPackage("stripe", good); nil != err {
			t.Fatalf("%q must be accepted: %v", good, err)
		}
	}

	for _, bad := range []string{
		"", "./local", "/abs/path", "~/home", "https://cdn.example/x.js",
		"c:\\win\\path",
		// NOT IMPLIED BY THE PREFIX CHECKS: this starts with neither `.`
		// nor `/`, and a host resolving it walks out of the named
		// dependency into application-local code.
		"pkg/../../escape",
	} {
		_, err := station.CheckPackage("stripe", bad)
		serr := expectCode(t, "station_sdk_load", err)
		if !strings.Contains(serr.Message, "module name") {
			t.Fatalf("message for %q: %v", bad, serr)
		}
	}
}

func toFloat(val any) float64 {
	switch n := val.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	}
	return 0
}
