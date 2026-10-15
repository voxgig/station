// The secret broker (design §5): sekreto resolves, station places. The
// broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.
package station

import (
	"encoding/hex"
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

const upperhex = "0123456789ABCDEF"

// EncodeQueryValue turns every UTF-8 byte outside RFC 3986's unreserved
// set into upper-case %XX.
func EncodeQueryValue(value string) string {
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		b := value[i]
		if ('A' <= b && b <= 'Z') || ('a' <= b && b <= 'z') ||
			('0' <= b && b <= '9') || 0 <= strings.IndexByte("-._~", b) {
			out.WriteByte(b)
		} else {
			out.WriteByte('%')
			out.WriteByte(upperhex[b>>4])
			out.WriteByte(upperhex[b&0x0f])
		}
	}
	return out.String()
}

func matchAt(text string, at int, end int, placeholder string) int {
	i := at
	for j := 0; j < len(placeholder); j++ {
		if i < end && text[i] == placeholder[j] {
			i++
			continue
		}
		if i+3 <= end && '%' == text[i] {
			if decoded, err := hex.DecodeString(text[i+1 : i+3]); nil == err &&
				decoded[0] == placeholder[j] {
				i += 3
				continue
			}
		}
		return -1
	}
	return i - at
}

// Substitute places value where placeholder stands in the header values
// and in the URL query, where an SDK percent-encodes it (any hex case) and
// the value is encoded in turn. The path and fragment are never touched;
// the headers are a copy.
func Substitute(fullurl string, headers map[string]any, placeholder string,
	value string) (string, map[string]any) {

	out := make(map[string]any, len(headers))
	for name, raw := range headers {
		if text, is := raw.(string); is && "" != placeholder {
			raw = strings.ReplaceAll(text, placeholder, value)
		}
		out[name] = raw
	}

	q := strings.IndexByte(fullurl, '?')
	hash := strings.IndexByte(fullurl, '#')
	if "" == placeholder || -1 == q || (-1 != hash && hash < q) {
		return fullurl, out
	}
	end := len(fullurl)
	if -1 != hash {
		end = hash
	}
	encoded := EncodeQueryValue(value)
	var query strings.Builder
	for i := q + 1; i < end; {
		if n := matchAt(fullurl, i, end, placeholder); 0 < n {
			query.WriteString(encoded)
			i += n
		} else {
			query.WriteByte(fullurl[i])
			i++
		}
	}
	return fullurl[:q+1] + query.String() + fullurl[end:], out
}

// redactValues matches every form of every value against the original
// text and redacts the union of the matches, so no replacement can hide
// another form.
func redactValues(text string, values []string) string {
	forms := []string{}
	for _, value := range values {
		if "" != value {
			forms = append(forms, value, EncodeQueryValue(value))
		}
	}
	reach := func(at int) int {
		end := at
		for _, form := range forms {
			if at+len(form) > end && strings.HasPrefix(text[at:], form) {
				end = at + len(form)
			}
		}
		return end
	}

	var out strings.Builder
	for i := 0; i < len(text); {
		stop := reach(i)
		if stop == i {
			out.WriteByte(text[i])
			i++
			continue
		}
		for j := i + 1; j < stop; j++ {
			if end := reach(j); end > stop {
				stop = end
			}
		}
		out.WriteString("[redacted]")
		i = stop
	}
	return out.String()
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

	// sekreto's Redact runs second; run first, it could split an encoded form.
	return broker.sek.Redact(redactValues(text, broker.held))
}

// refresh drops caches so the next resolve asks the stores again
// (rotation support rides on sekreto's Refresh, design §5.3).
func (broker *secretBroker) refresh() {
	broker.mu.Lock()
	defer broker.mu.Unlock()
	broker.cache = map[string]string{}
	broker.sek.Refresh()
}
