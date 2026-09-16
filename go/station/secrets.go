// The secret broker (design §5): sekreto resolves, station places. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.
package station

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"

	"github.com/voxgig/sekreto/go/plugins"
	"github.com/voxgig/sekreto/go/sekreto"
)

// PlaceholderFor is the inert value planted in options.apikey (design
// §5.3 R1). The `placeholder` corpus section pins the exact string.
//
// §7.2: KEYED BY INSTANCE. Two live instances of one api must have
// distinct placeholders or the injection seam cannot tell which
// credential a header wants. For an untagged instance this is the api
// slug, so the single-instance case is unchanged.
func PlaceholderFor(name string) string {
	return "[station:" + name + "]"
}

type secretBroker struct {
	mu  sync.Mutex
	sek *sekreto.Sekreto
	// Values hoisted by adopt-style binding from a resident
	// options.apikey (design §3.1).
	overrides map[string]string
	cache     map[string]string
	// Every value this broker ever held, for the exact-value scrub.
	held []string
}

// newSecretBroker builds the broker over sekreto's declarative
// ProviderSpec form - the profile's providers array, passed through
// untouched (design §5.2).
func newSecretBroker(providers []any) (*secretBroker, error) {
	text, err := json.Marshal(providers)
	if nil != err {
		return nil, fail("station_secret_error", "invalid provider chain: "+err.Error())
	}
	var specs []*sekreto.ProviderSpec
	if err := json.Unmarshal(text, &specs); nil != err {
		return nil, fail("station_secret_error", "invalid provider chain: "+err.Error())
	}
	// sekreto.New, not MakeNamedChain + NewNamed: sekreto folded the
	// named-chain pair into one constructor when its provider kinds moved
	// onto voxgig/plugin (sekreto 43eb579). The store name a chain entry
	// answers to is now ProviderSpec.Name, carried in the spec itself, so
	// the names no longer travel beside the chain. Caching stays on, which
	// is what the old `false` (nocache) argument asked for.
	// plugins.All(), because a control surface does not get to choose the
	// chain: the profile does, at run time, and station must honour any
	// kind a station.json names. sekreto's split put everything except
	// dotenv/env/file/memory behind a plugin definition the caller passes
	// in (sekreto 43eb579), so without this a profile naming `hashicorp`
	// -- or `minivault` -- fails at open() with "unknown provider kind".
	//
	// This is the case sekreto's own plugins package documents as its
	// reason to exist ("the CLI, the conformance suite, an app whose chain
	// is decided at run time"). The cost is link size, which is the wrong
	// thing to optimise in the process that brokers every credential.
	sek, err := sekreto.New(&sekreto.Options{
		Plugins:   plugins.All(),
		Providers: specs,
	})
	if nil != err {
		return nil, fail("station_secret_error", err.Error())
	}
	return &secretBroker{
		sek:       sek,
		overrides: map[string]string{},
		cache:     map[string]string{},
	}, nil
}

func (broker *secretBroker) hoist(instance string, value string) {
	broker.mu.Lock()
	defer broker.mu.Unlock()
	broker.overrides[instance] = value
	broker.held = append(broker.held, value)
}

// value resolves the value for an instance's secret name. Misses and
// store errors keep sekreto's distinction (design §5.2): a miss is
// station_secret_no_value, a store that could not answer is
// station_secret_error with sekreto's message intact - and never a
// retry against a weaker store (sekreto owns the chain).
//
// OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
// SECRET NAME (§5.3). A hoisted credential belongs to the one instance
// it was resident in, but a resolved VALUE belongs to the name it was
// resolved for - so several instances sharing one api-level `secret`
// cost one lookup rather than one each, and every client an auto-tagged
// Create() produces shares the declared instance's entry instead of
// re-resolving per request. Keying the cache by instance instead is the
// defect this replaces: at 26 instances over 20 apis it turns one store
// round-trip into 26.
func (broker *secretBroker) value(instance string, name string) (string, error) {
	broker.mu.Lock()
	defer broker.mu.Unlock()

	if override, has := broker.overrides[instance]; has {
		return override, nil
	}
	if cached, has := broker.cache[name]; has {
		return cached, nil
	}

	found, err := broker.sek.Get(name)
	if nil != err {
		var sekerr *sekreto.SekretoError
		if errors.As(err, &sekerr) && strings.Contains(sekerr.Message, "unknown secret") {
			return "", fail("station_secret_no_value",
				"no store had \""+name+"\" for plugin \""+instance+"\"")
		}
		return "", fail("station_secret_error", err.Error())
	}

	broker.cache[name] = found
	broker.held = append(broker.held, found)
	return found, nil
}

// scrub is the exact-value scrub, deliberately WITHOUT sekreto's
// four-character readability floor (design §7 as revised): on boundaries
// where the promise is absolute, every held value is scrubbed whatever
// its length. sekreto's own Redact() runs too, covering values resolved
// by the underlying instance that station never held.
func (broker *secretBroker) scrub(text string) string {
	broker.mu.Lock()
	defer broker.mu.Unlock()

	out := broker.sek.Redact(text)
	for _, value := range broker.held {
		if "" != value {
			out = strings.Join(strings.Split(out, value), "[redacted]")
		}
	}
	return out
}

// refresh drops caches so the next resolve asks the stores again
// (rotation support rides on sekreto's Refresh, design §5.3).
func (broker *secretBroker) refresh() {
	broker.mu.Lock()
	defer broker.mu.Unlock()
	broker.cache = map[string]string{}
	broker.sek.Refresh()
}
