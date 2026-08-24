// The factory table (design §6.2).
//
// A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
// function. Station composes the ordered feature array FOR the
// constructor, so it needs the transport roles and the feature option
// schemas BEFORE construction - but the adapter builds and registers its
// descriptor DURING construction. Nothing would be known in time.
//
// The config is available, though: the generated package emits it as a
// package-level variable, so it exists as soon as the package is linked
// and long before any instance is built. Station normalizes the
// descriptor AT PROVIDE TIME, and three things follow:
//
//   - the per-api descriptor cache is populated at registration rather
//     than on first construction;
//   - Check() can validate every instance's feature config WITHOUT
//     constructing anything;
//   - the adapter's registration during construction becomes a
//     reconciliation - same descriptor, now bound to a live client -
//     rather than the first sighting.
//
// The table is PROCESS-GLOBAL because path 1 of §6.2 is module
// self-registration: a generated package registers itself when it is
// linked, which happens once per process and not once per Station. In Go
// that path is a `func init()` on a blank import, which actually runs -
// see README.md for the three paths this port supports and the one
// (§6.3's loader) it cannot.
//
// A port of typescript/src/factory.ts, which is canonical.
package station

import (
	"reflect"
	"sort"
	"sync"
)

// Factory is what a generated package hands station: how to construct
// the SDK, and the SDK's own embedded config.
type Factory struct {
	// Construct builds the client from station-built options - the
	// generated constructor, exactly as the inverted binding calls it.
	Construct func(options map[string]any) any
	// Config is the SDK's embedded config (the value the generated
	// package exports beside its constructor).
	Config map[string]any
}

// FactoryEntry is one registered api: the factory, plus the descriptor
// normalized at provide time.
type FactoryEntry struct {
	API        string
	Construct  func(options map[string]any) any
	Config     map[string]any
	Descriptor map[string]any
	Warnings   []string
}

var (
	factoryMu sync.Mutex
	factories = map[string]*FactoryEntry{}
)

// Provide registers an api's construct/config pair.
//
// Idempotent per api: registering the SAME pair twice is a no-op,
// because module self-registration and an explicit Provide for one api
// is an ordinary thing for an application to end up with. A second
// registration with a DIFFERENT factory PANICS with
// station_factory_conflict - silently picking one of two SDK builds is
// not a thing to do quietly, and this is construction-time
// misconfiguration reached from `func init()`, where an error return has
// nowhere to go (the same idiom as Open's conflict and the wrap-order
// guard).
//
// "The same pair" is IDENTITY, as in the canonical library: Go funcs are
// not comparable, so both halves are compared by the pointer behind
// them. A generated package's constructor and config variable are one
// value each per process, so self-registration plus an explicit Provide
// of the same package compare equal.
func Provide(api string, factory Factory) *FactoryEntry {
	slug := api

	factoryMu.Lock()
	prior, has := factories[slug]
	factoryMu.Unlock()

	if has {
		if samefunc(prior.Construct, factory.Construct) &&
			samemap(prior.Config, factory.Config) {
			return prior
		}
		panic(fail("station_factory_conflict",
			"two different factories registered for api \""+slug+"\"; a "+
				"process has one build of an SDK, and picking between two "+
				"silently is not a thing to do quietly"))
	}

	// AT PROVIDE TIME, which is the whole point of carrying `config`.
	descriptor, warnings := NormalizeDescriptor(factory.Config, nil)
	entry := &FactoryEntry{
		API:        slug,
		Construct:  factory.Construct,
		Config:     factory.Config,
		Descriptor: descriptor,
		Warnings:   warnings,
	}

	factoryMu.Lock()
	defer factoryMu.Unlock()
	// Re-check under the lock: two goroutines linking two packages that
	// provide the same api must not race into two entries.
	if prior, has := factories[slug]; has {
		if samefunc(prior.Construct, factory.Construct) &&
			samemap(prior.Config, factory.Config) {
			return prior
		}
		panic(fail("station_factory_conflict",
			"two different factories registered for api \""+slug+"\"; a "+
				"process has one build of an SDK, and picking between two "+
				"silently is not a thing to do quietly"))
	}
	factories[slug] = entry
	return entry
}

// FactoryFor looks up a registered api, or nil.
func FactoryFor(api string) *FactoryEntry {
	factoryMu.Lock()
	defer factoryMu.Unlock()
	return factories[api]
}

// Provided lists the registered api slugs, sorted.
func Provided() []string {
	factoryMu.Lock()
	defer factoryMu.Unlock()
	out := make([]string, 0, len(factories))
	for slug := range factories {
		out = append(out, slug)
	}
	sort.Strings(out)
	return out
}

// ResetFactories clears the table. TEST SEAM ONLY: the table is
// process-global by design, so a suite that registers factories has to
// be able to put the process back.
func ResetFactories() {
	factoryMu.Lock()
	defer factoryMu.Unlock()
	factories = map[string]*FactoryEntry{}
}

func samefunc(a func(map[string]any) any, b func(map[string]any) any) bool {
	if nil == a || nil == b {
		return nil == a && nil == b
	}
	return reflect.ValueOf(a).Pointer() == reflect.ValueOf(b).Pointer()
}

func samemap(a map[string]any, b map[string]any) bool {
	if nil == a || nil == b {
		return nil == a && nil == b
	}
	return reflect.ValueOf(a).Pointer() == reflect.ValueOf(b).Pointer()
}
