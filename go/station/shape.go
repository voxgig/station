// The config grammar, as data (design §4).
//
// TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
//
// struct drops the unexpected-key check for a map whose spec node ends
// up empty - "an empty spec object means the object can be open". An
// optional key is `['$ONE','$NIL', spec]`, and when the data does not
// carry that key the validator REMOVES it from the spec node. So a
// block whose keys are all optional degenerates into an open map
// exactly when the data has none of them, and `{"solar": {"bass": 1}}`
// validates clean - the one property the whole exercise is for,
// silently absent in the one case that matters.
//
// So: NormalizeConfig materializes every documented default, and
// ValidateConfig then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
// After normalization every container is present, so the shape can
// require them, so unexpected-key detection is live at every level and
// every error names its path.
//
// A port of typescript/src/shape.ts, which is canonical.
package station

import (
	_ "embed"
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/voxgig/sekreto/go/sekreto"
	voxgigstruct "github.com/voxgig/struct/go"
)

// ---------------------------------------------------------------------
// The defaults table - ONE table, two callers
// ---------------------------------------------------------------------

// ProfileDefaults are the profile-level containers. Safe to materialize
// early either way: they are containers, and a missing one merges as
// empty regardless. Built per call, so a caller cannot alias a shared
// default into a config.
func ProfileDefaults() map[string]func() any {
	return map[string]func() any{
		"secrets": func() any {
			return map[string]any{
				"providers": []any{map[string]any{"kind": "env"}},
			}
		},
		"api":     func() any { return map[string]any{} },
		"sdk":     func() any { return map[string]any{} },
		"feature": func() any { return map[string]any{} },
	}
}

// BlockDefaults are the block-level defaults. `feature` is a container
// and safe early.
//
// `active` IS NOT, and that is the whole timing rule: a default
// synthesized into an OVERLAY block overwrites the base's real value and
// silently reactivates an integration the base deliberately barred
// (§3.3). So the two consumers read this same table at different
// moments - ValidateConfig before, applied to every block, because a
// block with no present keys is an open map; the profile resolver AFTER,
// applied to the merged instance, because an absent key must stay absent
// through the merge.
func BlockDefaults() map[string]func() any {
	return map[string]func() any{
		"active":  func() any { return true },
		"feature": func() any { return map[string]any{} },
	}
}

// MergeSensitive names the one block key carrying the timing rule.
// Named rather than inferred, so a reader does not have to work out
// which of the two it is, and so a port can assert it.
var MergeSensitive = []string{"active"}

// Deterministic key order for the two defaults tables: Go's map type has
// none, and a default materialized in a different order in different
// runs is a diff nobody can read.
func defaultkeys(table map[string]func() any) []string {
	keys := make([]string, 0, len(table))
	for k := range table {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// ---------------------------------------------------------------------
// NormalizeConfig
// ---------------------------------------------------------------------

// NormalizeConfig materializes every documented default, DEFENSIVELY: a
// node that is not the kind it expects is left alone for validate to
// reject with a proper message. Pure data-in/data-out, which is what
// makes it portable to 22 languages and expressible in the corpus, and
// it NEVER MUTATES ITS INPUT - every map is copied before it is written
// into.
//
// THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE.
func NormalizeConfig(raw any) any {
	rawmap, is := raw.(map[string]any)
	if !is {
		return raw
	}

	out := copymap(rawmap)

	if _, has := out["station"]; !has {
		out["station"] = 1
	}
	if _, has := out["profiles"]; !has {
		out["profiles"] = map[string]any{}
	}
	rawprofiles, is := out["profiles"].(map[string]any)
	if !is {
		return out
	}

	profiles := map[string]any{}
	for pname, praw := range rawprofiles {
		p, is := praw.(map[string]any)
		if !is {
			profiles[pname] = praw
			continue
		}
		prof := copymap(p)

		pdefaults := ProfileDefaults()
		for _, k := range defaultkeys(pdefaults) {
			if _, has := prof[k]; !has {
				prof[k] = pdefaults[k]()
			}
		}
		// A `secrets` written without `providers` still gets the chain.
		if secrets, is := prof["secrets"].(map[string]any); is {
			if _, has := secrets["providers"]; !has {
				secrets = copymap(secrets)
				secrets["providers"] = []any{map[string]any{"kind": "env"}}
				prof["secrets"] = secrets
			}
		}
		prof["feature"] = normfeatures(prof["feature"])

		for _, bkey := range []string{"api", "sdk"} {
			rawblocks, is := prof[bkey].(map[string]any)
			if !is {
				continue
			}
			blocks := map[string]any{}
			for ref, braw := range rawblocks {
				b, is := braw.(map[string]any)
				if !is {
					blocks[ref] = braw
					continue
				}
				block := copymap(b)
				bdefaults := BlockDefaults()
				for _, k := range defaultkeys(bdefaults) {
					if _, has := block[k]; !has {
						block[k] = bdefaults[k]()
					}
				}
				block["feature"] = normfeatures(block["feature"])
				blocks[ref] = block
			}
			prof[bkey] = blocks
		}

		profiles[pname] = prof
	}
	out["profiles"] = profiles
	return out
}

// Per feature entry, at every level: `active` -> true.
//
// A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's own
// default is `active: false` for all but `log`, and
// `{"retry": {"retries": 3}}` plainly means "retry, with three
// attempts". It also keeps the feature map closed, for the same reason
// every other block needs one present key.
//
// Defensive like the rest: a non-map is returned untouched for validate
// to reject by path.
func normfeatures(f any) any {
	fmap, is := f.(map[string]any)
	if !is {
		return f
	}
	out := map[string]any{}
	for name, entry := range fmap {
		emap, ismap := entry.(map[string]any)
		if _, hasactive := emap["active"]; ismap && !hasactive {
			e := copymap(emap)
			e["active"] = true
			out[name] = e
			continue
		}
		out[name] = entry
	}
	return out
}

func copymap(src map[string]any) map[string]any {
	out := make(map[string]any, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

// ---------------------------------------------------------------------
// ValidateConfig
// ---------------------------------------------------------------------

// The shape artifact, `spec/config-shape.json` (§4.3 verbatim), is the
// copy every port reads. A Go port publishes a compiled module that
// cannot see `spec/` at run time - and ValidateConfig runs at Open(),
// not just under test - so the package EMBEDS a mirror of it.
// `make sync-shape` rewrites the mirror; testutil/shape_test.go
// deep-compares the two and fails on drift.
//
//go:embed config-shape.json
var configShapeJSON []byte

var configShape any

func init() {
	if err := json.Unmarshal(configShapeJSON, &configShape); nil != err {
		panic(fail("station_config_invalid",
			"the embedded config shape is not valid JSON: "+err.Error()))
	}
}

// ConfigShape returns a FRESH DEEP COPY of the shape on every call.
// struct's validate CONSUMES the spec it walks - it deletes satisfied
// `$ONE` branches as it goes - so handing it the parsed constant twice
// would validate the second config against a spec the first had already
// eaten.
func ConfigShape() any {
	return voxgigstruct.Clone(configShape)
}

// Credential-shaped keys (§5.2). `secret` is here AND is the one exempt
// key - see secretvalue below; a blanket deny would reject the very
// mechanism that keeps values out of the file.
var credentialKeys = []string{
	"apikey", "auth", "authorization", "token",
	"secret", "password", "credential", "bearer",
}

// The suffix rule catches `access_key`, `X-Api-Token` and friends in one
// rule rather than a growing list of spellings.
var credentialSuffix = []string{"_KEY", "_TOKEN", "_SECRET", "_PASSWORD"}

// §5.2's backstop, and it is stated as one rather than as a grammar.
// ValidName() is a NAME grammar, not a credential filter: it rejects
// uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
// credential formats - but a lowercase hex token passes it cleanly. A
// character class cannot tell a name from a secret.
//
// Derived names break on every separator (`voxgig_solardemo.apikey` runs
// 6/9/6) and a hand-written name for a human to read does too; a
// 24-character unbroken run is not a name anybody writes. Note this is a
// RUN bound, not a length bound: `acme_internal_billing_service.apikey`
// is 36 characters and passes, which is the false positive a naive
// length bound would produce.
const runBound = 24

var unbrokenRun = regexp.MustCompile(`[A-Za-z0-9]{24,}`)

var schemeRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.-]*://`)

var nonAlnum = regexp.MustCompile(`[^a-z0-9]+`)

// ValidateConfig takes the NORMALIZED form and raises
// `station_config_invalid` with EVERY struct error at once - an
// eighteen-instance config that touches three of them must not die
// because the eighteenth has a typo'd package name - then the §5.2
// scans.
//
// The §4.4 workarounds are merged into the SAME error as struct's own,
// which is this tranche's one structural deviation from the canonical
// two-throw order: a struct new enough to reject a first-element gap
// itself reports a DIFFERENT spelling ("to be one of ..."), and the
// corpus pins the explicit one - so the pinned message is produced here
// either way, and behavior is identical whatever struct version
// resolves.
//
// Handing it a raw config is the mistake §4.2 exists to prevent, so
// every caller goes through NormalizeConfig first.
func ValidateConfig(normalized any) (any, error) {
	errsref := voxgigstruct.ListRefCreate[any]()
	voxgigstruct.Validate(jsonnumbers(normalized), ConfigShape(),
		&voxgigstruct.Injection{Errs: errsref})

	errs := make([]string, 0, len(errsref.List))
	for _, one := range errsref.List {
		if text, is := one.(string); is {
			errs = append(errs, text)
			continue
		}
		errs = append(errs, CanonicalSerialize(one))
	}

	secrets, reserved, invalid := scanConfig(normalized)

	if 0 < len(errs) || 0 < len(invalid) {
		return nil, fail("station_config_invalid",
			strings.Join(append(errs, invalid...), "; ")+renamehint(normalized))
	}
	if 0 < len(reserved) {
		return nil, fail("station_feature_reserved", strings.Join(reserved, "; "))
	}
	if 0 < len(secrets) {
		return nil, fail("station_config_secret", strings.Join(secrets, "; "))
	}
	return normalized, nil
}

// `plugin` is REMOVED, not aliased (§3.4) - a deprecated alias would be
// a second grammar for one concept in seventeen ports. The shape already
// rejects it as an unexpected key; this says what to rename, because
// "unexpected key: plugin" alone does not, and the migration for a
// single-instance project is exactly this one rename.
func renamehint(cfg any) string {
	profiles := asMap(asMap(cfg)["profiles"])
	hit := []string{}
	for _, pname := range sortedKeys(profiles) {
		prof, is := profiles[pname].(map[string]any)
		if !is {
			continue
		}
		if _, has := prof["plugin"]; has {
			hit = append(hit, "profiles."+pname)
		}
	}
	if 0 == len(hit) {
		return ""
	}
	return "; rename `plugin` to `sdk` in " + strings.Join(hit, ", ") +
		" - the keys are unchanged, an untagged ref IS an api slug (§3.4)"
}

// The §5.2 scans, over the parts of the grammar that hold arbitrary
// data. Everything else is closed by construction and needs no scan -
// `profiles.<p>.secrets.providers` included, which is why a provider
// block may legitimately carry its own `auth` sub-map. Collects rather
// than raising; ValidateConfig owns the error order.
func scanConfig(cfg any) (secrets []string, reserved []string, invalid []string) {
	secrets, reserved, invalid = []string{}, []string{}, []string{}

	profiles := asMap(asMap(cfg)["profiles"])
	for _, pname := range sortedKeys(profiles) {
		prof, is := profiles[pname].(map[string]any)
		if !is {
			continue
		}
		ppath := "profiles." + pname

		checkconfigfeatures(prof["feature"], ppath+".feature",
			&secrets, &reserved, &invalid)

		for _, bkey := range []string{"api", "sdk"} {
			blocks, is := prof[bkey].(map[string]any)
			if !is {
				continue
			}
			for _, ref := range sortedKeys(blocks) {
				block, is := blocks[ref].(map[string]any)
				if !is {
					continue
				}
				bpath := ppath + "." + bkey + "." + ref

				// The block's own `secret` holds a NAME. ResolveProfile
				// checks it again per instance (station_secret_name);
				// this catches it at Open(), for the whole file at once.
				if val, has := block["secret"]; has {
					secretvalue(val, bpath+".secret", &secrets)
				}

				// `options` is passthrough to a generated constructor,
				// so it is the one place a value can hide.
				scan(block["options"], bpath+".options", &secrets, &reserved)
				checkconfigfeatures(block["feature"], bpath+".feature",
					&secrets, &reserved, &invalid)

				// §4.4's explicit checks, applied where the shape cannot
				// reach, raising the same code the shape would - and
				// pinned in the corpus so each workaround is removed
				// deliberately when struct is fixed rather than
				// forgotten.
				checkpolicy(block["policy"], bpath+".policy", &invalid)
			}
		}
	}

	return secrets, reserved, invalid
}

// A feature map at any level. `station` is reserved: station composes
// its own wrap and a config that reconfigures it is asking for a state
// the ordering rules cannot express (§8.4).
func checkconfigfeatures(f any, path string,
	secrets *[]string, reserved *[]string, invalid *[]string) {

	fmap, is := f.(map[string]any)
	if !is {
		return
	}
	for _, name := range sortedKeys(fmap) {
		fpath := path + "." + name
		if "station" == name {
			*reserved = append(*reserved, path+".station is reserved: station "+
				"composes its own wrap and it cannot be configured from station.json")
		}
		if order, is := asMap(fmap[name])["order"].(map[string]any); is {
			firstelement(order["before"], fpath+".order.before", invalid)
			firstelement(order["after"], fpath+".order.after", invalid)
		}
		scan(fmap[name], fpath, secrets, reserved)
	}
}

// The policy block's §4.4 workarounds, in one place because they are one
// class of gap: struct cannot check what its own defects hide.
//
//   - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists,
//     so element 0 escapes the shape (see firstelement below).
//   - `budget` is a map whose keys are ALL optional scalars, and struct
//     removes an unsatisfied optional key from the spec node - so
//     `budget: {rp: 1}` degenerates the spec into an open map and the
//     typo passes. `allow` does not have this problem (its `$CHILD` keys
//     stay in the spec whether or not the data carries them, keeping the
//     map closed), and neither does `policy` itself (`hosts` anchors
//     it); `budget` alone needs the explicit unexpected-key check,
//     phrased as struct would phrase it.
var budgetKeys = []string{"concurrency", "rps"}

func checkpolicy(policy any, path string, invalid *[]string) {
	pmap, is := policy.(map[string]any)
	if !is {
		return
	}

	firstelement(pmap["hosts"], path+".hosts", invalid)

	if allow, is := pmap["allow"].(map[string]any); is {
		firstelement(allow["op"], path+".allow.op", invalid)
		firstelement(allow["method"], path+".allow.method", invalid)
	}

	if budget, is := pmap["budget"].(map[string]any); is {
		unknown := []string{}
		for _, k := range sortedKeys(budget) {
			known := false
			for _, one := range budgetKeys {
				if one == k {
					known = true
					break
				}
			}
			if !known {
				unknown = append(unknown, k)
			}
		}
		if 0 < len(unknown) {
			*invalid = append(*invalid, "Unexpected keys at field "+path+
				".budget: "+strings.Join(unknown, ", "))
		}
	}
}

// §4.4: `$CHILD` in list mode DOES NOT VALIDATE ELEMENT 0. Verified:
// `["a", 1]` fails at index 1, `[1]` passes, at any list length. An
// upstream struct defect, filed as voxgig/struct#113.
//
// It reaches THREE string lists in this shape: `policy.hosts`, and the
// per-feature `order.before` / `order.after`. Applied where the shape
// cannot reach, raising the same code the shape would, and pinned in the
// corpus so the workaround is removed deliberately when struct is fixed
// rather than forgotten.
func firstelement(list any, path string, invalid *[]string) {
	items, is := list.([]any)
	if !is || 0 == len(items) {
		return
	}
	if _, is := items[0].(string); is {
		return
	}
	*invalid = append(*invalid, "Expected field "+path+".0 to be string, "+
		"but found "+shapekind(items[0])+": "+CanonicalSerialize(items[0]))
}

// Recursive over EVERY nested map and list, not just the top level - a
// credential one level down is the case a top-level scan misses.
func scan(node any, path string, secrets *[]string, reserved *[]string) {
	if items, is := node.([]any); is {
		for i, item := range items {
			scan(item, path+"."+strconv.Itoa(i), secrets, reserved)
		}
		return
	}
	if text, is := node.(string); is {
		userinfo(text, path, secrets)
		return
	}
	nmap, is := node.(map[string]any)
	if !is {
		return
	}

	for _, key := range sortedKeys(nmap) {
		kpath := path + "." + key
		val := nmap[key]

		// §8.6: station owns feature composition, so an
		// `options.feature` in a declarative config is a second,
		// unreconciled ordering input.
		if "feature" == key {
			*reserved = append(*reserved, kpath+" is reserved: configure "+
				"features under the block's own `feature` key, not through `options`")
			continue
		}

		if "secret" == strings.ToLower(key) {
			secretvalue(val, kpath, secrets)
			continue
		}

		if credentialkey(key) {
			*secrets = append(*secrets, kpath+" is a credential-shaped key: "+
				"station.json holds secret NAMES, never values (§5.2)")
			continue
		}

		scan(val, kpath, secrets, reserved)
	}
}

func credentialkey(key string) bool {
	low := nonAlnum.ReplaceAllString(strings.ToLower(key), "")
	for _, one := range credentialKeys {
		if one == low {
			return true
		}
	}
	tok := Envtoken(key)
	for _, suffix := range credentialSuffix {
		if strings.HasSuffix(tok, suffix) {
			return true
		}
	}
	return false
}

// A `secret`-named key holds a NAME, and that exemption is not a
// loophole - it is the whole design. THREE checks, not one, and they
// live in the same handful of lines precisely so a port cannot implement
// only the first and inherit the gap the others exist to close.
func secretvalue(val any, path string, secrets *[]string) {
	text, is := val.(string)
	if !is {
		*secrets = append(*secrets, path+" must be a secret name (a string), "+
			"but found "+shapekind(val))
		return
	}
	if !sekreto.ValidName(text) {
		*secrets = append(*secrets, path+" is not a valid sekreto name, so it "+
			"cannot be a name and must not be a value: "+CanonicalSerialize(text))
		return
	}
	if unbrokenRun.MatchString(text) {
		*secrets = append(*secrets, path+" contains an unbroken alphanumeric "+
			"run of "+strconv.Itoa(runBound)+" or more characters, which is not a name "+
			"anybody writes")
	}
}

// One rule about values rather than keys, because the `proxy` feature
// makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
// failure is not an error - it returns silently.
func userinfo(val string, path string, secrets *[]string) {
	if !schemeRe.MatchString(val) {
		return
	}
	rest := val[strings.Index(val, "://")+3:]
	if cut := strings.IndexAny(rest, "/?#"); -1 != cut {
		rest = rest[:cut]
	}
	at := strings.LastIndex(rest, "@")
	if -1 == at || 0 == at {
		return
	}
	*secrets = append(*secrets, path+" is a URL carrying userinfo, which puts "+
		"a credential in the config file; use the proxy feature's `fromEnv` "+
		"option instead (§8.6)")
}

// JSON HAS ONE NUMBER TYPE AND GO HAS FIFTEEN, and struct's `$EXACT`
// compares with reflect.DeepEqual - so a config written in code with
// `"station": 1` (a Go int) does not equal the shape's JSON 1 and would
// fail a rule it plainly satisfies. Every number is therefore normalized
// to the kind encoding/json produces before the validator sees it.
//
// A COPY, and only the validator sees it: the scans, the corpus's
// expected output and every caller downstream read the normalized config
// itself, unchanged. Nothing else in struct is type-strict this way -
// `$INTEGER` accepts a Go int and a whole float alike.
func jsonnumbers(node any) any {
	switch v := node.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, one := range v {
			out[k] = jsonnumbers(one)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, one := range v {
			out[i] = jsonnumbers(one)
		}
		return out
	case float64, string, bool, nil:
		return node
	}
	if num, is := tonum(node); is {
		return num
	}
	return node
}

// The SHAPE kindof, which must agree with struct's own spellings. NOT
// the same function as the feature checker's (feature.go featurekind) -
// they disagree on numbers and maps deliberately, and unifying them
// would make one of the two message sets wrong.
func shapekind(val any) string {
	switch v := val.(type) {
	case nil:
		return "null"
	case []any:
		return "list"
	case map[string]any:
		return "object"
	case bool:
		return "boolean"
	case string:
		return "string"
	case float64:
		if v == float64(int64(v)) {
			return "integer"
		}
		return "decimal"
	case float32:
		if float64(v) == float64(int64(v)) {
			return "integer"
		}
		return "decimal"
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return "integer"
	}
	return "object"
}
