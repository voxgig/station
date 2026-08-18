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

	"github.com/voxgig/sekreto/go/sekreto"
)

// PlaceholderFor is the inert value planted in options.apikey (design
// §5.3 R1). The `placeholder` corpus section pins the exact string.
func PlaceholderFor(slug string) string {
	return "[station:" + slug + "]"
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
	chain, names, err := sekreto.MakeNamedChain(specs)
	if nil != err {
		return nil, fail("station_secret_error", err.Error())
	}
	return &secretBroker{
		sek:       sekreto.NewNamed(chain, names, false),
		overrides: map[string]string{},
		cache:     map[string]string{},
	}, nil
}

func (broker *secretBroker) hoist(slug string, value string) {
	broker.mu.Lock()
	defer broker.mu.Unlock()
	broker.overrides[slug] = value
	broker.held = append(broker.held, value)
}

// value resolves the value for a plugin's secret name. Misses and store
// errors keep sekreto's distinction (design §5.2): a miss is
// station_secret_no_value, a store that could not answer is
// station_secret_error with sekreto's message intact - and never a
// retry against a weaker store (sekreto owns the chain).
func (broker *secretBroker) value(slug string, name string) (string, error) {
	broker.mu.Lock()
	defer broker.mu.Unlock()

	if override, has := broker.overrides[slug]; has {
		return override, nil
	}
	if cached, has := broker.cache[slug]; has {
		return cached, nil
	}

	found, err := broker.sek.Get(name)
	if nil != err {
		var sekerr *sekreto.SekretoError
		if errors.As(err, &sekerr) && strings.Contains(sekerr.Message, "unknown secret") {
			return "", fail("station_secret_no_value",
				"no store had \""+name+"\" for plugin \""+slug+"\"")
		}
		return "", fail("station_secret_error", err.Error())
	}

	broker.cache[slug] = found
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
