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

func PlaceholderFor(name string) string {
	return "[station:" + name + "]"
}

type secretBroker struct {
	mu        sync.Mutex
	sek       *sekreto.Sekreto
	overrides map[string]string
	cache     map[string]string
	held      []string
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
