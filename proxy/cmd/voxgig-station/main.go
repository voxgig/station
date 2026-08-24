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
	case "run":
		if err := runCmd(os.Args[2:]); err != nil {
			log.Fatalf("voxgig-station: %v", err)
		}
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

func usage(w *os.File) {
	fmt.Fprintf(w, `voxgig-station - station companion daemon (control-plane core)

Usage:
  voxgig-station run [flags]   start the daemon
  voxgig-station version       print version
  voxgig-station help          this text

Run flags:
  --listen addr        listen address (default %s; or VOXGIG_STATION_URL)
  --token-file path    token file (default ~/.voxgig/station/token)
  --session-ttl dur    session liveness TTL (default %s)
  --ring n             event ring capacity (default %d)
`, daemon.DefaultListen, daemon.DefaultSessionTTL, daemon.DefaultRingCapacity)
}

func runCmd(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	listen := fs.String("listen", "", "listen address host:port (default "+daemon.DefaultListen+")")
	tokenFile := fs.String("token-file", "", "token file path (default ~/.voxgig/station/token)")
	sessionTTL := fs.Duration("session-ttl", daemon.DefaultSessionTTL, "session liveness TTL")
	ringCap := fs.Int("ring", daemon.DefaultRingCapacity, "event ring capacity (entries)")
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

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w", addr, err)
	}

	srv := daemon.NewServer(daemon.Config{
		// The resolved address, so a ":0" bind still yields a correct
		// Host/Origin allowlist.
		Listen:       ln.Addr().String(),
		TokenPath:    tokenPath,
		SessionTTL:   *sessionTTL,
		RingCapacity: *ringCap,
	}, token)

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
