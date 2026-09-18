package station

import (
	"fmt"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------
// §8.3 - the merge
// ---------------------------------------------------------------------

// ReservedKeys are reserved on a feature entry: not options, and never
// passed through to the SDK's own option map.
var ReservedKeys = []string{"active", "order"}

func reservedkey(key string) bool {
	for _, one := range ReservedKeys {
		if one == key {
			return true
		}
	}
	return false
}

func MergeFeatures(sources []map[string]any) map[string]any {
	out := map[string]any{}
	for _, src := range sources {
		if nil == src {
			continue
		}
		for _, name := range sortedKeys(src) {
			entry, is := src[name].(map[string]any)
			if !is {
				// A non-map entry replaces wholesale.
				out[name] = src[name]
				continue
			}
			// Per option key, and NOT deeper.
			merged := map[string]any{}
			for k, v := range asMap(out[name]) {
				merged[k] = v
			}
			for k, v := range entry {
				merged[k] = v
			}
			out[name] = merged
		}
	}
	return out
}

// MergeFeatureOrder is the declaration order of the map MergeFeatures
// builds from the same sources: first appearance, reading each source in
// the order given. `orders` is per-source and may be nil or short - a
// source with no order is read in sorted-key order, since a Go map has
// none of its own.
func MergeFeatureOrder(sources []map[string]any, orders [][]string) []string {
	out := []string{}
	seen := map[string]bool{}
	for i, src := range sources {
		if nil == src {
			continue
		}
		var order []string
		if i < len(orders) {
			order = orders[i]
		}
		for _, name := range namesInOrder(src, order) {
			if !seen[name] {
				seen[name] = true
				out = append(out, name)
			}
		}
	}
	return out
}

// namesInOrder reads a map's keys in the declared order, then any key
// the order did not name, sorted. Defensive on both sides: an order
// naming an absent key contributes nothing, and a key no order names is
// never dropped.
func namesInOrder(node map[string]any, order []string) []string {
	out := make([]string, 0, len(node))
	seen := map[string]bool{}
	for _, name := range order {
		if _, has := node[name]; has && !seen[name] {
			seen[name] = true
			out = append(out, name)
		}
	}
	for _, name := range sortedKeys(node) {
		if !seen[name] {
			seen[name] = true
			out = append(out, name)
		}
	}
	return out
}

func FeatureSources(base map[string]any, overlay map[string]any,
	api string, ref string) []map[string]any {

	return []map[string]any{
		asMap(base["feature"]),
		asMap(asMap(asMap(base["api"])[api])["feature"]),
		asMap(asMap(asMap(base["sdk"])[ref])["feature"]),
		asMap(overlay["feature"]),
		asMap(asMap(asMap(overlay["api"])[api])["feature"]),
		asMap(asMap(asMap(overlay["sdk"])[ref])["feature"]),
	}
}

func FeatureSourcePaths(baseName string, overlayName string,
	api string, ref string) [][]string {

	return [][]string{
		{"profiles", baseName, "feature"},
		{"profiles", baseName, "api", api, "feature"},
		{"profiles", baseName, "sdk", ref, "feature"},
		{"profiles", overlayName, "feature"},
		{"profiles", overlayName, "api", api, "feature"},
		{"profiles", overlayName, "sdk", ref, "feature"},
	}
}

// ---------------------------------------------------------------------
// §8.4 - activation and order
// ---------------------------------------------------------------------

const (
	BandDefault = 0
	BandStation = 100
	BandTest    = 200
)

// DefaultBand is the band a feature takes when it declares none.
func DefaultBand(name string) int {
	if "test" == name {
		return BandTest
	}
	if "station" == name {
		return BandStation
	}
	return BandDefault
}

// OrderedFeature is one row of the resolved order, outermost first.
type OrderedFeature struct {
	Name  string
	Band  float64
	Entry any
}

// Active reports whether a feature entry is on. A feature named in the
// config is one you are ASKING for, so an entry with no `active` is
// active.
func Active(entry any) bool {
	emap, is := entry.(map[string]any)
	if !is {
		return false != entry
	}
	return false != emap["active"]
}

func ResolveOrder(merged map[string]any, declared []string) (
	[]OrderedFeature, error) {

	names := []string{}
	for _, n := range namesInOrder(merged, declared) {
		if Active(merged[n]) {
			names = append(names, n)
		}
	}

	pos := map[string]int{}
	band := map[string]float64{}
	for i, n := range names {
		pos[n] = i
		b := float64(DefaultBand(n))
		if order, is := asMap(merged[n])["order"].(map[string]any); is {
			if num, isnum := tonum(order["band"]); isnum {
				b = num
			}
		}
		band[n] = b
	}

	// Edges from OUTER to INNER. `after: X` means "further in than X".
	inner := map[string][]string{}
	known := map[string]bool{}
	for _, n := range names {
		inner[n] = []string{}
		known[n] = true
	}

	addedge := func(outer string, in string) {
		for _, one := range inner[outer] {
			if one == in {
				return
			}
		}
		inner[outer] = append(inner[outer], in)
	}

	for _, n := range names {
		order, is := asMap(merged[n])["order"].(map[string]any)
		if !is {
			continue
		}
		// Vacuous when absent: an unknown name is not an error here.
		for _, other := range listof(order["after"]) {
			if known[other] {
				addedge(other, n)
			}
		}
		for _, other := range listof(order["before"]) {
			if known[other] {
				addedge(n, other)
			}
		}
	}

	// A missing key reads 0, so only the increments need writing.
	indeg := map[string]int{}
	for _, n := range names {
		for _, m := range inner[n] {
			indeg[m]++
		}
	}

	// Kahn, picking the lowest band first (outermost), then declaration
	// position - so ties break the same way in every port.
	ready := []string{}
	for _, n := range names {
		if 0 == indeg[n] {
			ready = append(ready, n)
		}
	}

	out := []OrderedFeature{}
	for 0 < len(ready) {
		sort.SliceStable(ready, func(i, j int) bool {
			a, b := ready[i], ready[j]
			if band[a] != band[b] {
				return band[a] < band[b]
			}
			return pos[a] < pos[b]
		})
		n := ready[0]
		ready = ready[1:]

		out = append(out, OrderedFeature{Name: n, Band: band[n], Entry: merged[n]})
		for _, m := range inner[n] {
			indeg[m]--
			if 0 == indeg[m] {
				ready = append(ready, m)
			}
		}
	}

	if len(out) != len(names) {
		emitted := map[string]bool{}
		for _, one := range out {
			emitted[one.Name] = true
		}
		stuck := []string{}
		for _, n := range names {
			if !emitted[n] {
				stuck = append(stuck, n)
			}
		}
		sort.Strings(stuck)
		return nil, fail("station_feature_order",
			"feature ordering constraints form a cycle among ["+
				strings.Join(stuck, ", ")+"]")
	}

	return out, nil
}

func CheckPin(ordered []OrderedFeature) error {
	at := indexOfFeature(ordered, "station")
	if -1 == at {
		return nil
	}

	base := indexOfFeature(ordered, "test")
	// station must be the innermost wrapper: last, or immediately
	// outside the base-transport feature when one is active.
	want := len(ordered) - 1
	if -1 != base {
		want = base - 1
	}
	if at != want {
		return fail("station_feature_order",
			"an ordering would move `station` away from immediately outside "+
				"the base transport; its position is pinned innermost and is "+
				"not orderable (§8.4)")
	}
	return nil
}

func indexOfFeature(ordered []OrderedFeature, name string) int {
	for i, one := range ordered {
		if name == one.Name {
			return i
		}
	}
	return -1
}

// FeatureNames projects the resolved rows to their names, which is the
// §8.7 view and the corpus's expected shape.
func FeatureNames(ordered []OrderedFeature) []string {
	out := make([]string, 0, len(ordered))
	for _, one := range ordered {
		out = append(out, one.Name)
	}
	return out
}

// ComposeFeatures composes the ordered rows into the ORDERED ARRAY FORM
// the constructor takes. No new seam: it is what the inverted binding
// already does for station's own placement, with more in it.
func ComposeFeatures(ordered []OrderedFeature) []map[string]any {
	out := make([]map[string]any, 0, len(ordered))
	for _, row := range ordered {
		entry := asMap(row.Entry)
		one := map[string]any{"name": row.Name, "active": true}
		for _, k := range sortedKeys(entry) {
			if reservedkey(k) {
				continue
			}
			one[k] = entry[k]
		}
		out = append(out, one)
	}
	return out
}

// ---------------------------------------------------------------------
// §8.5 - the checker, derived from the descriptor
// ---------------------------------------------------------------------

// Fault is one §8.5 complaint. CheckFeatures COLLECTS them; the callers
// own the failure.
type Fault struct {
	Code    string
	Feature string
	Key     string
	Message string
}

func CheckFeatures(merged map[string]any, descriptor map[string]any) []Fault {
	faults := []Fault{}

	byname := map[string]map[string]any{}
	declaredNames := []string{}
	if rows, is := descriptor["features"].([]any); is {
		for _, raw := range rows {
			row := asMap(raw)
			if nil == row {
				continue
			}
			name := fmt.Sprint(row["name"])
			byname[name] = row
			declaredNames = append(declaredNames, name)
		}
	}
	sort.Strings(declaredNames)

	for _, name := range sortedKeys(merged) {
		spec, has := byname[name]
		if !has {
			faults = append(faults, Fault{
				Code:    "station_feature_unknown",
				Feature: name,
				Message: "the SDK has no feature \"" + name + "\"; it declares [" +
					strings.Join(declaredNames, ", ") + "]",
			})
			continue
		}

		entry, is := merged[name].(map[string]any)
		if !is {
			continue
		}
		defaults := asMap(spec["options"])

		for _, key := range sortedKeys(entry) {
			if reservedkey(key) {
				continue
			}

			def, hasdef := defaults[key]
			if !hasdef {
				// THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is
				// accepted and silently ignored today, because the SDK's
				// own feature spec is `$OPEN` per feature so the SDK
				// cannot catch it and nothing else looks.
				faults = append(faults, Fault{
					Code: "station_feature_option", Feature: name, Key: key,
					Message: "feature \"" + name + "\" declares no option \"" +
						key + "\"; it declares [" +
						strings.Join(sortedKeys(defaults), ", ") + "]",
				})
				continue
			}

			want := featurekind(def)
			got := featurekind(entry[key])
			if want != got {
				faults = append(faults, Fault{
					Code: "station_feature_option", Feature: name, Key: key,
					Message: "feature \"" + name + "\" option \"" + key +
						"\" expects " + want + ", but found " + got + ": " +
						CanonicalSerialize(entry[key]),
				})
			}
		}
	}

	return faults
}

// FaultMessages joins the faults' messages, which is the one error a
// caller raises for the lot of them.
func FaultMessages(faults []Fault) string {
	out := make([]string, 0, len(faults))
	for _, one := range faults {
		out = append(out, one.Message)
	}
	return strings.Join(out, "; ")
}

func featurekind(val any) string {
	switch val.(type) {
	case nil:
		return "null"
	case []any:
		return "list"
	case map[string]any:
		return "map"
	case bool:
		return "boolean"
	case string:
		return "string"
	}
	if _, is := tonum(val); is {
		return "number"
	}
	return "map"
}

// listof accepts a single value or a list of them, stringified.
func listof(val any) []string {
	if nil == val {
		return []string{}
	}
	if items, is := val.([]any); is {
		out := make([]string, 0, len(items))
		for _, one := range items {
			out = append(out, stringify(one))
		}
		return out
	}
	return []string{stringify(val)}
}

func stringify(val any) string {
	if text, is := val.(string); is {
		return text
	}
	if num, is := tonum(val); is {
		return CanonicalSerialize(num)
	}
	return fmt.Sprint(val)
}

func tonum(val any) (float64, bool) {
	switch n := val.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int8:
		return float64(n), true
	case int16:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint:
		return float64(n), true
	case uint8:
		return float64(n), true
	case uint16:
		return float64(n), true
	case uint32:
		return float64(n), true
	case uint64:
		return float64(n), true
	}
	return 0, false
}
