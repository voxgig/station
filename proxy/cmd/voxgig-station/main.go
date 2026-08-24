// Command voxgig-station is the station companion daemon (design D2):
// one Go binary providing the consolidated control surface for every
// attached station library. This phase ships the control-plane core -
// token + discovery (§8.1), register/session/events/tap/status
// (§8.2/§8.3) - single-team, in-memory. The data plane (/v1/forward),
// grants, proxy-side policy authority, capture store, replay/mock and
// the MCP surface arrive in later phases; their CLI verbs (tap, status,
// call, approve, revoke, mcp) land alongside them.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/voxgig/station/proxy/internal/daemon"
)

func main() {
	log.SetFlags(0)
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	switch os.Args[1] {
	// `run` is the canonical daemon verb (the §11 quickstart:
	// `voxgig-station run`); `serve` aliases it for operators expecting
	// the conventional name.
	case "run", "serve":
		if err := runCmd(os.Args[2:]); err != nil {
			log.Fatalf("voxgig-station: %v", err)
		}
	case "status":
		exitOnErr(statusCmd(os.Args[2:]))
	case "approve":
		exitOnErr(approveCmd(os.Args[2:]))
	case "tap":
		exitOnErr(tapCmd(os.Args[2:]))
	case "mcp":
		exitOnErr(mcpCmd(os.Args[2:]))
	case "version":
		fmt.Printf("voxgig-station %s (protocol %d)\n", daemon.Version, daemon.Protocol)
	case "help", "-h", "--help":
		usage(os.Stdout)
	default:
		fmt.Fprintf(os.Stderr, "voxgig-station: unknown command %q\n\n", os.Args[1])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func exitOnErr(err error) {
	if err == nil {
		return
	}
	log.Fatalf("voxgig-station: %v", err)
}

func usage(w *os.File) {
	fmt.Fprintf(w, `voxgig-station - the station companion proxy (design D2)

Usage:
  voxgig-station run [flags]            start the daemon (alias: serve)
  voxgig-station status [flags]         show plugins, sessions, stores, bounds
  voxgig-station approve <ref> [flags]  bless an instance's base/hosts/name triple
  voxgig-station tap [plugin] [flags]   stream live events as NDJSON
  voxgig-station mcp [flags]            MCP server on stdio (bridges to the daemon)
  voxgig-station version                print version
  voxgig-station help                   this text

Run flags:
  --listen addr          listen address (default %s; or VOXGIG_STATION_URL)
  --token-file path      token file (default ~/.voxgig/station/token)
  --config path          proxy-side station.json (default: cwd-up lookup)
  --profile name         station.json profile (default VOXGIG_STATION_PROFILE, else "default")
  --state-file path      approval state (default: approvals.json beside the token)
  --session-ttl dur      session liveness TTL (default %s)
  --grant-ttl dur        R2 grant TTL (default %s)
  --ring n               event ring capacity (default %d)
  --capture-entries n    capture store entry bound (default %d)
  --capture-bytes n      capture store byte bound (default %d)
  --capture-body n       capture body truncation point (default %d)
  --forward-body n       /v1/forward request-body limit (default %d)
  --events-body n        /v1/events batch limit (default %d)
  --register-body n      /v1/register body limit (default %d)
  --event-line n         single event line limit (default %d)
  --tap-buffer n         per-subscriber tap buffer (default %d)
  --poll-timeout dur     policy long-poll hold time (default %s)
  --upstream-timeout dur upstream exchange timeout (default %s)
  --agent-write          arm the daemon half of the mutating-agent gate (default off)
  --agent-read           the agent.read knob (default true locally)

Verb flags (status / approve / tap):
  --url u                daemon URL (default: VOXGIG_STATION_URL, else http://%s)
  --token t              bearer token (default: read the token file)
  --token-file path      token file (default ~/.voxgig/station/token)

Every verb authenticates the daemon first: a nonce on /v1/health must
come back with a valid Station-Proof before the bearer token is sent.
`, daemon.DefaultListen, daemon.DefaultSessionTTL, daemon.DefaultGrantTTL,
		daemon.DefaultRingCapacity, daemon.DefaultCaptureMaxEntries,
		daemon.DefaultCaptureMaxBytes, daemon.DefaultCaptureBodyLimit,
		daemon.DefaultForwardBodyLimit, daemon.DefaultEventsBodyLimit,
		daemon.DefaultRegisterBodyLimit, daemon.DefaultEventLineLimit,
		daemon.DefaultTapBuffer, daemon.DefaultPolicyPollTimeout,
		daemon.DefaultUpstreamTimeout, daemon.DefaultListen)
}

func runCmd(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	listen := fs.String("listen", "", "listen address host:port (default "+daemon.DefaultListen+")")
	tokenFile := fs.String("token-file", "", "token file path (default ~/.voxgig/station/token)")
	sessionTTL := fs.Duration("session-ttl", daemon.DefaultSessionTTL, "session liveness TTL")
	ringCap := fs.Int("ring", daemon.DefaultRingCapacity, "event ring capacity (entries)")
	configPath := fs.String("config", "", "proxy-side station.json (default: cwd-up lookup, then ~/.voxgig/station.json)")
	profile := fs.String("profile", "", "station.json profile (default: VOXGIG_STATION_PROFILE, else \"default\")")
	stateFile := fs.String("state-file", "", "approval state file (default: approvals.json beside the token file)")
	grantTTL := fs.Duration("grant-ttl", daemon.DefaultGrantTTL, "R2 grant TTL")
	captureEntries := fs.Int("capture-entries", daemon.DefaultCaptureMaxEntries, "capture store entry bound")
	captureBytes := fs.Int64("capture-bytes", daemon.DefaultCaptureMaxBytes, "capture store byte bound")
	captureBody := fs.Int("capture-body", daemon.DefaultCaptureBodyLimit, "capture body truncation point (bytes)")
	forwardBody := fs.Int64("forward-body", daemon.DefaultForwardBodyLimit, "/v1/forward request-body limit (bytes)")
	eventsBody := fs.Int64("events-body", daemon.DefaultEventsBodyLimit, "/v1/events batch limit (bytes)")
	upstreamTimeout := fs.Duration("upstream-timeout", daemon.DefaultUpstreamTimeout, "upstream exchange timeout")
	registerBody := fs.Int64("register-body", daemon.DefaultRegisterBodyLimit, "/v1/register body limit (bytes)")
	eventLine := fs.Int("event-line", daemon.DefaultEventLineLimit, "single event line limit (bytes)")
	tapBuffer := fs.Int("tap-buffer", daemon.DefaultTapBuffer, "per-subscriber tap buffer (events)")
	pollTimeout := fs.Duration("poll-timeout", daemon.DefaultPolicyPollTimeout, "policy long-poll hold time")
	agentWrite := fs.Bool("agent-write", false, "arm the daemon half of the mutating-agent gate (§7; instance policy agent.write is also required)")
	agentRead := fs.Bool("agent-read", true, "the §7 agent.read knob (default true on a local proxy)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	// §8.1: default 127.0.0.1:8299, configurable via --listen /
	// VOXGIG_STATION_URL. The explicit flag outranks the environment
	// (the §3.5 precedence rule, applied to the daemon's own surface).
	addr := daemon.DefaultListen
	if env := os.Getenv("VOXGIG_STATION_URL"); env != "" {
		fromEnv, err := listenFromURL(env)
		if err != nil {
			return fmt.Errorf("VOXGIG_STATION_URL: %w", err)
		}
		addr = fromEnv
	}
	if *listen != "" {
		addr = *listen
	}

	tokenPath := *tokenFile
	if tokenPath == "" {
		var err error
		tokenPath, err = daemon.DefaultTokenPath()
		if err != nil {
			return err
		}
	}
	token, err := daemon.LoadOrCreateToken(tokenPath)
	if err != nil {
		return err
	}

	// §8.3: the proxy loads its OWN station.json - same lookup the
	// libraries use (cwd upward to the repo root, then
	// ~/.voxgig/station.json), with --config overriding.
	cfgPath := *configPath
	if cfgPath == "" {
		cfgPath = daemon.FindStationConfig("")
	}
	profileName := *profile
	if profileName == "" {
		profileName = os.Getenv("VOXGIG_STATION_PROFILE")
	}
	// Approval state lives beside the token file (§8.3): triples only,
	// never values.
	statePath := *stateFile
	if statePath == "" {
		statePath = filepath.Join(filepath.Dir(tokenPath), "approvals.json")
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w", addr, err)
	}

	srv, err := daemon.NewServer(daemon.Config{
		// The resolved address, so a ":0" bind still yields a correct
		// Host/Origin allowlist.
		Listen:            ln.Addr().String(),
		TokenPath:         tokenPath,
		SessionTTL:        *sessionTTL,
		RingCapacity:      *ringCap,
		StationConfigPath: cfgPath,
		Profile:           profileName,
		StatePath:         statePath,
		GrantTTL:          *grantTTL,
		CaptureMaxEntries: *captureEntries,
		CaptureMaxBytes:   *captureBytes,
		CaptureBodyLimit:  *captureBody,
		ForwardBodyLimit:  *forwardBody,
		EventsBodyLimit:   *eventsBody,
		UpstreamTimeout:   *upstreamTimeout,
		RegisterBodyLimit: *registerBody,
		EventLineLimit:    *eventLine,
		TapBuffer:         *tapBuffer,
		PolicyPollTimeout: *pollTimeout,
		AgentWrite:        *agentWrite,
		AgentReadDisabled: !*agentRead,
	}, token)
	if err != nil {
		ln.Close()
		return err
	}

	httpSrv := &http.Server{
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() { errCh <- httpSrv.Serve(ln) }()

	// The token value itself is never logged.
	log.Printf("voxgig-station %s: listening on http://%s (token file %s)",
		daemon.Version, ln.Addr(), tokenPath)

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			// Open tap streams keep Shutdown waiting; after the grace
			// period, close them out.
			_ = httpSrv.Close()
		}
		return nil
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// listenFromURL turns a VOXGIG_STATION_URL value (a base URL, e.g.
// http://127.0.0.1:8299) into a listen address, defaulting the port to
// 8299 when absent. Only http is meaningful for a local loopback daemon;
// TLS is remote mode, a later phase (§8.4).
func listenFromURL(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("not a URL: %q", raw)
	}
	if u.Scheme != "http" {
		return "", fmt.Errorf("unsupported scheme %q (local daemon speaks http)", u.Scheme)
	}
	if u.Host == "" {
		return "", fmt.Errorf("no host in %q", raw)
	}
	if u.Port() == "" {
		return net.JoinHostPort(u.Hostname(), "8299"), nil
	}
	return u.Host, nil
}
