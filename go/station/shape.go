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

var credentialSuffix = []string{"_KEY", "_TOKEN", "_SECRET", "_PASSWORD"}

const runBound = 24

var unbrokenRun = regexp.MustCompile(`[A-Za-z0-9]{24,}`)

var schemeRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.-]*://`)

var nonAlnum = regexp.MustCompile(`[^a-z0-9]+`)

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
