// The descriptor normalizer and canonical serializer (design §4).
//
// A port of typescript/src/descriptor.ts, which is canonical.
package station

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

var envtokenRe = regexp.MustCompile(`[^A-Z0-9]+`)

// Envtoken is the ONLY way to build an env-var token in station,
// mirroring sdkgen's packageMeta envToken exactly:
// 'gnarly-pets' -> 'GNARLY_PETS'. The `secretname` corpus section pins
// the round-trip against sekreto's EnvKey() and sdkgen's envName() - the
// one place three grammars meet.
func Envtoken(name any) string {
	text := ""
	if s, is := name.(string); is {
		text = s
	} else if nil != name {
		text = fmt.Sprint(name)
	}
	text = envtokenRe.ReplaceAllString(strings.ToUpper(text), "_")
	return strings.Trim(text, "_")
}

// SecretnameDefault is the default sekreto name for a plugin (design
// §5.1): Envtoken(slug) lowercased, plus '.apikey'. sekreto's EnvKey()
// then yields exactly the env var the SDK's README documents:
// gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
func SecretnameDefault(slug string) string {
	return strings.ToLower(Envtoken(slug)) + ".apikey"
}

// Best-effort slug from a camel name, for SDKs whose embedded config
// predates main.slug (design §4 legacy sentinels). The hyphen caveat is
// real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT 'voxgig-solardemo' -
// callers surface a warning event when this path is taken.
func legacySlug(name string) string {
	return strings.ToLower(name)
}

func asMap(val any) map[string]any {
	m, _ := val.(map[string]any)
	return m
}

func asString(val any) string {
	s, _ := val.(string)
	return s
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// NormalizeDescriptor turns a generated SDK's embedded config into
// descriptor v1 (design §4). The config is the one every SDK carries
// (config main / feature / options / entity); the descriptor is a VIEW
// over it - map-shaped, like everything else the go SDKs hand around.
// Returns the descriptor plus any legacy warnings.
func NormalizeDescriptor(config map[string]any, activeFeatures map[string]any) (
	map[string]any, []string) {

	warnings := []string{}
	main := asMap(config["main"])
	options := asMap(config["options"])

	name := asString(main["name"])
	slug := asString(main["slug"])
	if "" == slug {
		slug = legacySlug(name)
		warnings = append(warnings, "descriptor: legacy config has no main.slug; "+
			"derived \""+slug+"\" from the camel name - hyphens in the original "+
			"name are lost")
	}

	version := "0.0.0"
	if v, has := main["version"]; has && nil != v {
		version = fmt.Sprint(v)
	}
	target := "unknown"
	if t, has := main["target"]; has && nil != t {
		target = fmt.Sprint(t)
	}

	server := []any{}
	svr := asMap(options["server"])
	for _, k := range sortedKeys(svr) {
		server = append(server, map[string]any{"name": k, "value": fmt.Sprint(svr[k])})
	}

	authActive := nil != options["auth"]
	authPrefix := ""
	if authActive {
		authPrefix = asString(asMap(options["auth"])["prefix"])
	}
	auth := map[string]any{
		"active":     authActive,
		"prefix":     authPrefix,
		"secretname": SecretnameDefault(slug),
	}

	entities := map[string]any{}
	entdefs := asMap(config["entity"])
	for _, ename := range sortedKeys(entdefs) {
		e := asMap(entdefs[ename])

		fields := map[string]any{}
		if flist, is := e["fields"].([]any); is {
			for _, f := range flist {
				fm := asMap(f)
				if nil == fm || nil == fm["name"] {
					continue
				}
				kind := asString(fm["kind"])
				if "" == kind {
					kind = asString(fm["type"])
				}
				fields[asString(fm["name"])] = map[string]any{"kind": kind}
			}
		}

		ops := map[string]any{}
		opdefs := asMap(e["op"])
		for _, opname := range sortedKeys(opdefs) {
			op := asMap(opdefs[opname])
			points := []any{}
			if plist, is := op["points"].([]any); is {
				for _, p := range plist {
					pm := asMap(p)
					if nil == pm {
						continue
					}
					path := asString(pm["orig"])
					if "" == path {
						path = asString(pm["path"])
					}
					params := []any{}
					if parts, is := pm["parts"].([]any); is {
						for _, part := range parts {
							if s, is := part.(string); is && strings.HasPrefix(s, ":") {
								params = append(params, s[1:])
							}
						}
					}
					point := map[string]any{
						"method": asString(pm["method"]),
						"path":   path,
						"params": params,
					}
					if sel, has := pm["select"]; has && nil != sel {
						point["select"] = sel
					}
					points = append(points, point)
				}
			}
			ops[opname] = map[string]any{"points": points}
		}

		entities[ename] = map[string]any{"fields": fields, "ops": ops}
	}

	features := []any{}
	fdefs := asMap(config["feature"])
	for _, fname := range sortedKeys(fdefs) {
		active := false
		if fopts := asMap(activeFeatures[fname]); nil != fopts {
			active = true == fopts["active"]
		}
		features = append(features, map[string]any{"name": fname, "active": active})
	}

	descriptor := map[string]any{
		"station":  1,
		"name":     name,
		"slug":     slug,
		"envtoken": Envtoken(slug),
		"version":  version,
		"target":   target,
		"base":     asString(options["base"]),
		"server":   server,
		"auth":     auth,
		"entities": entities,
		"features": features,
	}

	return descriptor, warnings
}

// CanonicalSerialize is the canonical serialization of design §4: UTF-8,
// object keys sorted bytewise, no insignificant whitespace, minimal JSON
// escaping. The proxy dedupes registrations by a hash of this, so every
// language must produce identical bytes - the `canonical-serialize`
// corpus section carries the adversarial cases.
func CanonicalSerialize(value any) string {
	var out strings.Builder
	canonicalWrite(&out, value)
	return out.String()
}

func canonicalWrite(out *strings.Builder, value any) {
	switch v := value.(type) {
	case nil:
		out.WriteString("null")
	case map[string]any:
		// Go string comparison is bytewise over UTF-8, which is exactly
		// the descriptor spec's key order.
		keys := make([]string, 0, len(v))
		for k := range v {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out.WriteByte('{')
		for i, k := range keys {
			if 0 < i {
				out.WriteByte(',')
			}
			out.WriteString(scalarJSON(k))
			out.WriteByte(':')
			canonicalWrite(out, v[k])
		}
		out.WriteByte('}')
	case []any:
		out.WriteByte('[')
		for i, item := range v {
			if 0 < i {
				out.WriteByte(',')
			}
			canonicalWrite(out, item)
		}
		out.WriteByte(']')
	default:
		out.WriteString(scalarJSON(value))
	}
}

// scalarJSON encodes a scalar with minimal escaping. encoding/json's
// number formatting already matches JavaScript's (integers up to 2^53
// print in full digits, floats shortest-round-trip); its HTML escaping
// does not, so it is disabled.
func scalarJSON(value any) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); nil != err {
		return "null"
	}
	return strings.TrimRight(buf.String(), "\n")
}
