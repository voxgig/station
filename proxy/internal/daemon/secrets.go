// The proxy-side secret broker (design §5.3 R2): the PROXY holds the
// sekreto instance and the provider credentials; the application process
// never runs the chain. Resolution happens by the proxy's OWN
// instance→name mapping (§8.3) - a client can never choose which secret
// is resolved. Values live in memory only (§8.5); every value this
// broker ever resolved joins the exact-value scrub set, no length floor
// (§7 - the promise on the capture/agent boundary is absolute).
//
// The sekreto usage pattern follows go/station/secrets.go, the library
// port.
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
	// held is every value ever resolved - the persistent half of the
	// capture scrub set. (Station-Redact values are deliberately NOT
	// added here: §15 holds those transiently, for one exchange only.)
	held []string
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

// resolveErr distinguishes §5.2's two failure kinds on the wire: a miss
// (no store had the name) is station_secret_no_value; a store that
// could not answer is station_secret_error with sekreto's message
// intact - and never retried against a weaker store (sekreto owns the
// chain).
type resolveErr struct {
	code    string
	message string
}

func (e *resolveErr) Error() string { return e.code + ": " + e.message }

// value resolves a secret name through the proxy's chain. The resolution
// cache is keyed by secret name (§5.3), so several instances naming one
// secret share a single resolution.
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

// heldValues snapshots the persistent scrub set (for capture scrubbing
// alongside an exchange's transient Station-Redact values).
func (b *broker) heldValues() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.held...)
}

// chainSources describes the chain for station_secrets - sekreto's own
// Sources() strings ("env:<prefix>", "memory", "hashicorp", ...), safe
// by construction (§7).
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

// redactedMarker replaces scrubbed bytes in captures and tool output.
const redactedMarker = "[redacted]"
