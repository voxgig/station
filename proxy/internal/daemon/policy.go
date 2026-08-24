// Proxy-side policy authority (design §8.3, §16).
//
// Everything a client registers is untrusted input, so under
// `resolve: proxy` the instance→secret-name mapping, the provider chain,
// and the hosts egress allowlist all come from configuration the PROXY
// loads itself - its own station.json, its own profile resolution, its
// own sekreto instance. Where nothing proxy-side covers an instance
// there is no first-seen shortcut: the plugin parks in `pending` -
// registered, visible in status, capture and library-resolved traffic
// working - until `approve` explicitly blesses the base/hosts/name
// triple, and any later change to that triple re-enters pending.
//
// The config loading here is a trimmed port of typescript/src/profile.ts
// (canonical) / go/station/profile.go: same lookup convention, same §3.5
// flat four-source merge with profile specificity outranking block
// specificity, same wholesale replacement of `secrets.providers`.
package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/voxgig/sekreto/go/sekreto"
)

// Registration/approval states (§8.3).
const (
	StatePending  = "pending"
	StateApproved = "approved"
)

var envtokenRe = regexp.MustCompile(`[^A-Z0-9]+`)

// envtoken normalizes a name the way sdkgen's envToken does (§5.1: one
// rule, one place - this is that rule, ported): uppercase, every run of
// non-alphanumerics collapsed to `_`, trimmed.
func envtoken(name string) string {
	return strings.Trim(envtokenRe.ReplaceAllString(strings.ToUpper(name), "_"), "_")
}

// secretnameDefault derives the default sekreto name for an instance ref
// (§5.1): envtoken lowercased plus `.apikey` - `voxgig-solardemo` →
// `voxgig_solardemo.apikey`, `stripe$test` → `stripe_test.apikey`.
func secretnameDefault(ref string) string {
	return strings.ToLower(envtoken(ref)) + ".apikey"
}

// refapi returns the api half of a ref: the substring before the first
// `$`. An untagged ref IS an api slug (§3.2).
func refapi(ref string) string {
	if at := strings.Index(ref, "$"); at != -1 {
		return ref[:at]
	}
	return ref
}

// FindStationConfig looks for station.json from `from` (default: the
// working directory) upward to the repo root (where .git lives), then
// ~/.voxgig/station.json - the §3.5 lookup, same as profile.ts. Empty
// when nothing is found.
func FindStationConfig(from string) string {
	if from == "" {
		from, _ = os.Getwd()
	}
	dir, err := filepath.Abs(from)
	if err != nil {
		dir = from
	}
	for {
		candidate := filepath.Join(dir, "station.json")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		_, repoErr := os.Stat(filepath.Join(dir, ".git"))
		parent := filepath.Dir(dir)
		if repoErr == nil || parent == dir {
			break
		}
		dir = parent
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidate := filepath.Join(home, ".voxgig", "station.json")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

// instanceEntry is the merged proxy-side config for one instance ref.
type instanceEntry map[string]any

func (e instanceEntry) str(key string) string {
	s, _ := e[key].(string)
	return s
}

func (e instanceEntry) hosts() []string {
	policy, _ := e["policy"].(map[string]any)
	raw, _ := policy["hosts"].([]any)
	out := make([]string, 0, len(raw))
	for _, h := range raw {
		if s, ok := h.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

// stationConfig is the proxy's resolved view of its own station.json.
type stationConfig struct {
	File      string
	Profile   string
	Providers []any
	// Sdk holds the §3.5-merged instance entries, keyed by ref.
	Sdk map[string]instanceEntry
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	if m == nil {
		return map[string]any{}
	}
	return m
}

func shallow(sources ...map[string]any) map[string]any {
	out := map[string]any{}
	for _, src := range sources {
		for k, v := range src {
			out[k] = v
		}
	}
	return out
}

func mergedKeys(maps ...map[string]any) []string {
	seen := map[string]bool{}
	for _, m := range maps {
		for k := range m {
			seen[k] = true
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// loadStationConfig reads and resolves the proxy-side station.json at
// path for profileName. Nil config (no error) when path is empty.
//
// §3.5's total order for the two block levels, lowest precedence first -
// ONE FLAT LEFT-TO-RIGHT MERGE, never "collapse each namespace first":
//
//	base.api[<api>] ⊕ base.sdk[<ref>] ⊕ overlay.api[<api>] ⊕ overlay.sdk[<ref>]
//
// Merging within a block is shallow per key - an overlay's `policy`
// REPLACES the base's wholesale rather than merging `hosts` into it,
// the only safe reading for an allowlist. `secrets.providers` replaces
// wholesale at the profile level (§5.2).
func loadStationConfig(path string, profileName string) (*stationConfig, error) {
	if path == "" {
		return nil, nil
	}
	text, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("station: cannot read config %s: %w", path, err)
	}
	var raw map[string]any
	if err := json.Unmarshal(text, &raw); err != nil {
		return nil, fmt.Errorf("station: config %s is not valid JSON: %w", path, err)
	}

	profiles := asMap(raw["profiles"])
	base := asMap(profiles["default"])
	overlay := map[string]any{}
	if profileName != "default" {
		overlay = asMap(profiles[profileName])
	}

	providers := providersOf(overlay)
	if providers == nil {
		providers = providersOf(base)
	}
	if providers == nil {
		// Omitting the block means today's behavior: one env provider
		// (§5.2, §11).
		providers = []any{map[string]any{"kind": "env"}}
	}

	baseApi, overApi := asMap(base["api"]), asMap(overlay["api"])
	baseSdk, overSdk := asMap(base["sdk"]), asMap(overlay["sdk"])

	sdk := map[string]instanceEntry{}
	for _, ref := range mergedKeys(baseSdk, overSdk) {
		a := refapi(ref)
		sdk[ref] = shallow(
			asMap(baseApi[a]), asMap(baseSdk[ref]),
			asMap(overApi[a]), asMap(overSdk[ref]),
		)
	}

	// A configured secret name sekreto would reject is caught at load,
	// not first request (§14 station_secret_name).
	for ref, entry := range sdk {
		if name, has := entry["secret"]; has && name != nil {
			if !sekreto.ValidName(name) {
				return nil, fmt.Errorf(
					"station: %s profile %q sdk %q: secret name rejected by sekreto: %v (station_secret_name)",
					path, profileName, ref, name)
			}
		}
	}

	return &stationConfig{
		File: path, Profile: profileName, Providers: providers, Sdk: sdk,
	}, nil
}

func providersOf(profile map[string]any) []any {
	secrets := asMap(profile["secrets"])
	if providers, is := secrets["providers"].([]any); is {
		return providers
	}
	return nil
}

// Approval is one blessed base/hosts/name triple (§8.3). NEVER a secret
// value - the state file persists exactly these fields.
type Approval struct {
	Ref        string   `json:"ref"`
	Base       string   `json:"base,omitempty"`
	Hosts      []string `json:"hosts"`
	Secret     string   `json:"secret"` // sekreto NAME, never a value
	ApprovedAt string   `json:"approvedAt"`
}

// approvalState is the state file shape.
type approvalState struct {
	Station   int                 `json:"station"`
	Approvals map[string]Approval `json:"approvals"`
}

// Effective is the policy view a forward/register consults for one ref.
type Effective struct {
	Ref      string
	State    string // pending | approved
	Covered  bool   // a proxy-side profile entry exists for the ref
	Hosts    []string
	Secret   string // sekreto name
	Base     string
	Resolve  string // library | proxy
	Capture  string // meta | headers | full
	Version  int
	Approved *Approval
}

// PolicyStore is the proxy-side policy authority: the resolved config,
// the approval table (persisted), and the per-ref version counters that
// drive the GET /v1/policy/{ref} long-poll.
type PolicyStore struct {
	mu        sync.Mutex
	cfg       *stationConfig // nil when no proxy-side config
	approvals map[string]Approval
	statePath string
	now       func() time.Time
	versions  map[string]int
	waiters   map[string]chan struct{}
}

func NewPolicyStore(cfg *stationConfig, statePath string, now func() time.Time) (*PolicyStore, error) {
	p := &PolicyStore{
		cfg:       cfg,
		approvals: map[string]Approval{},
		statePath: statePath,
		now:       now,
		versions:  map[string]int{},
		waiters:   map[string]chan struct{}{},
	}
	if statePath != "" {
		text, err := os.ReadFile(statePath)
		if err == nil {
			var state approvalState
			if err := json.Unmarshal(text, &state); err != nil {
				return nil, fmt.Errorf("station: approval state %s is not valid JSON: %w", statePath, err)
			}
			if state.Approvals != nil {
				p.approvals = state.Approvals
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("station: cannot read approval state %s: %w", statePath, err)
		}
	}
	return p, nil
}

// saveLocked persists the approval table - triples only, 0600 like the
// token file it sits beside.
func (p *PolicyStore) saveLocked() error {
	if p.statePath == "" {
		return nil
	}
	state := approvalState{Station: 1, Approvals: p.approvals}
	text, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.statePath), 0o700); err != nil {
		return err
	}
	return os.WriteFile(p.statePath, append(text, '\n'), 0o600)
}

// entryFor returns the merged config entry for ref, if covered.
func (p *PolicyStore) entryFor(ref string) (instanceEntry, bool) {
	if p.cfg == nil {
		return nil, false
	}
	e, ok := p.cfg.Sdk[ref]
	return e, ok
}

// secretNameFor is the proxy-side instance→secret-name mapping (§8.3:
// never taken from the client): the config's explicit `secret`, else the
// §5.1 derivation from the ref.
func (p *PolicyStore) secretNameFor(ref string) string {
	if entry, ok := p.entryFor(ref); ok {
		if name := entry.str("secret"); name != "" {
			return name
		}
	}
	return secretnameDefault(ref)
}

// approvedLocked reports the standing approval for ref, if it is still
// valid: any later change to the config-derived parts of the triple
// (base, hosts, secret name) re-enters pending (§8.3). Config parts the
// profile does not declare are governed by the blessed snapshot itself.
func (p *PolicyStore) approvedLocked(ref string) *Approval {
	approval, ok := p.approvals[ref]
	if !ok {
		return nil
	}
	if approval.Secret != p.secretNameFor(ref) {
		return nil
	}
	if entry, covered := p.entryFor(ref); covered {
		if base := entry.str("base"); base != "" && base != approval.Base {
			return nil
		}
		if hosts := entry.hosts(); len(hosts) > 0 && !equalStrings(hosts, approval.Hosts) {
			return nil
		}
	}
	return &approval
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// EffectiveFor computes the current policy view for ref.
func (p *PolicyStore) EffectiveFor(ref string) Effective {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.effectiveLocked(ref)
}

func (p *PolicyStore) effectiveLocked(ref string) Effective {
	eff := Effective{
		Ref:     ref,
		State:   StatePending,
		Secret:  p.secretNameFor(ref),
		Resolve: "library",
		Capture: "meta",
		Version: p.versionLocked(ref),
	}
	entry, covered := p.entryFor(ref)
	eff.Covered = covered
	if covered {
		if r := entry.str("resolve"); r != "" {
			eff.Resolve = r
		}
		if c := entry.str("capture"); c != "" {
			eff.Capture = c
		}
		eff.Base = entry.str("base")
	}
	if approval := p.approvedLocked(ref); approval != nil {
		eff.State = StateApproved
		eff.Approved = approval
		eff.Hosts = approval.Hosts
		if approval.Base != "" {
			eff.Base = approval.Base
		}
	}
	return eff
}

// Approve blesses the base/hosts/name triple for ref (§8.3's
// `voxgig-station approve`). The triple comes from the proxy-side
// config where it covers the ref; the hosts default falls back to the
// base URL's host - config base first, else descriptorBase, the
// proxy-side view of a live registration's descriptor (§16). An
// approval that cannot determine any hosts allowlist fails: blessing an
// unbounded egress surface is exactly what approve exists to prevent.
func (p *PolicyStore) Approve(ref string, descriptorBase string) (Approval, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	entry, _ := p.entryFor(ref)
	base := ""
	hosts := []string{}
	if entry != nil {
		base = entry.str("base")
		hosts = entry.hosts()
	}
	if base == "" {
		base = descriptorBase
	}
	if len(hosts) == 0 && base != "" {
		if h := hostOfURL(base); h != "" {
			hosts = []string{h}
		}
	}
	if len(hosts) == 0 {
		return Approval{}, fmt.Errorf(
			"cannot determine a hosts allowlist for %q: no proxy-side policy.hosts or base, and no live registration supplies a base", ref)
	}

	approval := Approval{
		Ref:        ref,
		Base:       base,
		Hosts:      hosts,
		Secret:     p.secretNameFor(ref),
		ApprovedAt: p.now().UTC().Format(time.RFC3339),
	}
	p.approvals[ref] = approval
	if err := p.saveLocked(); err != nil {
		delete(p.approvals, ref)
		return Approval{}, fmt.Errorf("cannot persist approval: %w", err)
	}
	p.bumpLocked(ref)
	return approval, nil
}

// hostOfURL extracts the lowercased hostname of a base URL, "" when it
// does not parse.
func hostOfURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return ""
	}
	return strings.ToLower(u.Hostname())
}

// HostAllowed checks an egress hostname against an approved allowlist
// (§16). Entries match the hostname exactly, case-insensitive
// (host:port entries match hostname:port).
func hostAllowed(hosts []string, hostname string, port string) bool {
	hn := strings.ToLower(hostname)
	for _, h := range hosts {
		h = strings.ToLower(h)
		if h == hn {
			return true
		}
		if port != "" && h == hn+":"+port {
			return true
		}
	}
	return false
}

// NarrowHosts applies §8.3's narrow-never-widen rule: a registered
// descriptor whose base host is INSIDE the approved allowlist narrows
// this session's effective allowlist to that host; a base outside it is
// ignored entirely - untrusted input cannot widen approved policy.
func narrowHosts(approved []string, descriptorBase string) []string {
	dh := hostOfURL(descriptorBase)
	if dh == "" {
		return approved
	}
	if hostAllowed(approved, dh, "") {
		return []string{dh}
	}
	return approved
}

// versionLocked returns the current policy version for ref (starts at 1).
func (p *PolicyStore) versionLocked(ref string) int {
	if v, ok := p.versions[ref]; ok {
		return v
	}
	return 1
}

// bumpLocked advances ref's policy version and wakes long-pollers.
func (p *PolicyStore) bumpLocked(ref string) {
	p.versions[ref] = p.versionLocked(ref) + 1
	if ch, ok := p.waiters[ref]; ok {
		close(ch)
		delete(p.waiters, ref)
	}
}

// Bump is bumpLocked for other stores (grant revocation is a policy
// update the long-poll should deliver).
func (p *PolicyStore) Bump(ref string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.bumpLocked(ref)
}

// WaitChan returns (view, nil) when ref's version already differs from
// sinceVersion, else the channel the next bump closes.
func (p *PolicyStore) WaitChan(ref string, sinceVersion int) (Effective, <-chan struct{}) {
	p.mu.Lock()
	defer p.mu.Unlock()
	eff := p.effectiveLocked(ref)
	if eff.Version != sinceVersion {
		return eff, nil
	}
	ch, ok := p.waiters[ref]
	if !ok {
		ch = make(chan struct{})
		p.waiters[ref] = ch
	}
	return eff, ch
}

// Snapshot reports the covered and currently-approved refs for status.
func (p *PolicyStore) Snapshot() (file string, profile string, covered []string, approved []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cfg != nil {
		file, profile = p.cfg.File, p.cfg.Profile
		for ref := range p.cfg.Sdk {
			covered = append(covered, ref)
		}
	}
	for ref := range p.approvals {
		if p.approvedLocked(ref) != nil {
			approved = append(approved, ref)
		}
	}
	sort.Strings(covered)
	sort.Strings(approved)
	return file, profile, covered, approved
}
