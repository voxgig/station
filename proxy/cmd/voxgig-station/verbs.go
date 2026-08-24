// The operator verbs: status, approve, tap - the human skins of the
// wire API (§6: "the CLI and MCP tools are two skins over one proxy
// API"). Each verb runs the §8.1 proof-of-token handshake before
// sending anything sensitive.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
)

// statusCmd pretty-prints GET /v1/status (--json for the raw body).
func statusCmd(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	urlF, tokenF, tokenFileF := clientFlags(fs)
	jsonF := fs.Bool("json", false, "print the raw JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	c, err := resolveClient(*urlF, *tokenF, *tokenFileF)
	if err != nil {
		return err
	}
	if err := c.verifyProof(); err != nil {
		return err
	}
	resp, err := c.do(http.MethodGet, "/v1/status", nil)
	if err != nil {
		return err
	}
	st, err := decodeOrError(resp)
	if err != nil {
		return err
	}
	if *jsonF {
		return printJSON(st)
	}
	printStatus(st)
	return nil
}

func printJSON(v map[string]any) error {
	enc := jsonEncoder(os.Stdout)
	return enc.Encode(v)
}

func printStatus(st map[string]any) {
	num := func(v any) int64 {
		f, _ := v.(float64)
		return int64(f)
	}
	str := func(v any) string {
		s, _ := v.(string)
		return s
	}
	m := func(v any) map[string]any {
		mm, _ := v.(map[string]any)
		if mm == nil {
			return map[string]any{}
		}
		return mm
	}
	list := func(v any) []any {
		l, _ := v.([]any)
		return l
	}

	fmt.Printf("voxgig-station %s at %s — protocol %d, up %ds\n",
		str(st["version"]), str(st["listen"]), num(st["protocol"]), num(st["uptimeSeconds"]))

	plugins := list(st["plugins"])
	fmt.Printf("\nplugins (%d):\n", len(plugins))
	if len(plugins) == 0 {
		fmt.Println("  (none registered)")
	}
	for _, p := range plugins {
		pm := m(p)
		fmt.Printf("  %-30s %-9s sessions:%d\n",
			str(pm["plugin"]), str(pm["state"]), num(pm["sessions"]))
	}

	sessions := list(st["sessions"])
	fmt.Printf("\nsessions (%d):\n", len(sessions))
	if len(sessions) == 0 {
		fmt.Println("  (none)")
	}
	for _, s := range sessions {
		sm := m(s)
		proc := m(sm["process"])
		fmt.Printf("  %s  %-30s %-9s pid:%d lang:%s app:%s events:%d expires:%s\n",
			str(sm["session"])[:8], str(sm["plugin"]), str(sm["state"]),
			num(proc["pid"]), str(proc["lang"]), str(proc["app"]),
			num(sm["events"]), str(sm["expiresAt"]))
	}

	ev := m(st["events"])
	ring := m(ev["ring"])
	fmt.Printf("\nevents: ring %d/%d (total %d, dropped %d), invalid %d, tap subscribers %d (dropped %d)\n",
		num(ring["size"]), num(ring["capacity"]), num(ring["total"]), num(ring["dropped"]),
		num(ev["invalid"]), num(ev["tapSubscribers"]), num(ev["tapDropped"]))

	cap := m(st["captures"])
	fmt.Printf("captures: %d entries / %d bytes (bounds %d entries / %d bytes), evicted %d, degraded %d\n",
		num(cap["entries"]), num(cap["bytes"]), num(cap["maxEntries"]), num(cap["maxBytes"]),
		num(cap["evicted"]), num(cap["degraded"]))

	fmt.Printf("grants: %d active\n", num(m(st["grants"])["active"]))

	pol := m(st["policy"])
	file := str(pol["configFile"])
	if file == "" {
		file = "(no proxy-side station.json)"
	}
	fmt.Printf("policy: profile %q from %s\n", str(pol["profile"]), file)
	fmt.Printf("  covered:  %s\n", joinAny(list(pol["covered"])))
	fmt.Printf("  approved: %s\n", joinAny(list(pol["approved"])))

	bounds := m(st["bounds"])
	keys := make([]string, 0, len(bounds))
	for k := range bounds {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	fmt.Printf("bounds:")
	for _, k := range keys {
		fmt.Printf(" %s=%d", k, num(bounds[k]))
	}
	fmt.Println()
}

func joinAny(items []any) string {
	if len(items) == 0 {
		return "(none)"
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		s, _ := item.(string)
		out = append(out, s)
	}
	return strings.Join(out, ", ")
}

// approveCmd blesses one instance's base/hosts/name triple through the
// RUNNING daemon (POST /v1/approve/{ref}). The daemon owns approval
// state - this verb never writes a state file itself: with the daemon
// down there is exactly one authority to consult and it is absent, so
// the remedy is to start it, not to fork the state (§8.3).
func approveCmd(args []string) error {
	fs := flag.NewFlagSet("approve", flag.ExitOnError)
	urlF, tokenF, tokenFileF := clientFlags(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	ref := fs.Arg(0)
	if ref == "" || fs.NArg() > 1 {
		return fmt.Errorf("usage: voxgig-station approve [flags] <instance-ref>")
	}
	c, err := resolveClient(*urlF, *tokenF, *tokenFileF)
	if err != nil {
		return err
	}
	if err := c.verifyProof(); err != nil {
		return err
	}
	resp, err := c.do(http.MethodPost, "/v1/approve/"+url.PathEscape(ref), nil)
	if err != nil {
		return err
	}
	body, err := decodeOrError(resp)
	if err != nil {
		return err
	}
	approval, _ := body["approval"].(map[string]any)
	hosts, _ := approval["hosts"].([]any)
	fmt.Printf("approved %s\n  hosts:  %s\n  secret: %s (name only - values never leave the stores)\n",
		ref, joinAny(hosts), approval["secret"])
	return nil
}

// tapCmd streams GET /v1/tap to stdout as NDJSON until interrupted.
func tapCmd(args []string) error {
	fs := flag.NewFlagSet("tap", flag.ExitOnError)
	urlF, tokenF, tokenFileF := clientFlags(fs)
	pluginF := fs.String("plugin", "", "only events for this instance ref")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// `voxgig-station tap [plugin]` (§6) - the positional form works too.
	plugin := *pluginF
	if plugin == "" && fs.NArg() == 1 {
		plugin = fs.Arg(0)
	}
	c, err := resolveClient(*urlF, *tokenF, *tokenFileF)
	if err != nil {
		return err
	}
	if err := c.verifyProof(); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	path := "/v1/tap"
	if plugin != "" {
		path += "?plugin=" + url.QueryEscape(plugin)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Station-Protocol", "1")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := c.http.Do(req)
	if err != nil {
		return &daemonDown{base: c.base, err: err}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, err := decodeOrError(resp)
		return err
	}

	if plugin == "" {
		fmt.Fprintln(os.Stderr, "voxgig-station: tapping all instances (ctrl-c to stop)")
	} else {
		fmt.Fprintf(os.Stderr, "voxgig-station: tapping %q (ctrl-c to stop)\n", plugin)
	}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		fmt.Println(sc.Text())
	}
	if ctx.Err() != nil {
		return nil // interrupted by the operator
	}
	return sc.Err()
}
