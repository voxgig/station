package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/voxgig/sekreto/go/sekreto"
)

type broker struct {
	mu    sync.Mutex
	sek   *sekreto.Sekreto
	cache map[string]string
	held  []string
}

// newBroker builds the broker over sekreto's declarative ProviderSpec
// form - the profile's providers array, passed through untouched (§5.2:
// station neither extends nor validates the grammar; sekreto's own
// error is the one the operator sees).
func newBroker(providers []any) (*broker, error) {
	if providers == nil {
		providers = []any{map[string]any{"kind": "env"}}
	}
	text, err := json.Marshal(providers)
	if err != nil {
		return nil, fmt.Errorf("station: invalid provider chain: %w", err)
	}
	var specs []*sekreto.ProviderSpec
	if err := json.Unmarshal(text, &specs); err != nil {
		return nil, fmt.Errorf("station: invalid provider chain: %w", err)
	}
	chain, names, err := sekreto.MakeNamedChain(specs)
	if err != nil {
		return nil, fmt.Errorf("station: %s", err.Error())
	}
	return &broker{
		sek:   sekreto.NewNamed(chain, names, false),
		cache: map[string]string{},
	}, nil
}

type resolveErr struct {
	code    string
	message string
}

func (e *resolveErr) Error() string { return e.code + ": " + e.message }

func (b *broker) value(ref string, name string) (string, *resolveErr) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if cached, has := b.cache[name]; has {
		return cached, nil
	}

	found, err := b.sek.Get(name)
	if err != nil {
		var sekerr *sekreto.SekretoError
		if errors.As(err, &sekerr) && strings.Contains(sekerr.Message, "unknown secret") {
			return "", &resolveErr{code: CodeSecretNoValue,
				message: "no store had \"" + name + "\" for instance \"" + ref + "\""}
		}
		return "", &resolveErr{code: CodeSecretError, message: err.Error()}
	}

	b.cache[name] = found
	b.held = append(b.held, found)
	return found, nil
}

// scrub replaces every value this broker ever held, exact match,
// whatever its length - plus sekreto's own Redact for values the
// underlying instance resolved that station never saw (§7, §15).
func (b *broker) scrub(text string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := b.sek.Redact(text)
	for _, value := range b.held {
		if value != "" {
			out = strings.ReplaceAll(out, value, redactedMarker)
		}
	}
	return out
}

func (b *broker) heldValues() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.held...)
}

func (b *broker) chainSources() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.sek.Sources()
}

// storeFor reports which store answers for a name - sekreto's
// Stores()/HasIn, never Get: station_secrets reports placement, not
// values (§7). Empty store with nil error is a miss everywhere; an
// error is §5.2's "store could not answer", surfaced verbatim.
func (b *broker) storeFor(name string) (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, store := range b.sek.Stores() {
		has, err := b.sek.HasIn(store, name)
		if err != nil {
			return "", err
		}
		if has {
			return store, nil
		}
	}
	return "", nil
}

const redactedMarker = "[redacted]"
