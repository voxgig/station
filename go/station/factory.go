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
	Config    map[string]any
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
