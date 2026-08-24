// `voxgig-station mcp` - the stdio MCP transport (§7: stdio for
// `claude mcp add`; streamable HTTP on the daemon for shared use). The
// verb is a wire client of the running daemon, consistent with every
// other verb: it bridges newline-delimited JSON-RPC on stdio to POST
// /v1/mcp, so the eight tools have exactly one implementation - the
// daemon's - and the stdio and HTTP transports cannot drift.
package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
)

func mcpCmd(args []string) error {
	fs := flag.NewFlagSet("mcp", flag.ExitOnError)
	urlF, tokenF, tokenFileF := clientFlags(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	c, err := resolveClient(*urlF, *tokenF, *tokenFileF)
	if err != nil {
		return err
	}
	// §8.1 first, as everywhere: prove the daemon holds the token file
	// before a single MCP message - which may carry anything the host
	// chooses - crosses to it.
	if err := c.verifyProof(); err != nil {
		return err
	}

	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 8<<20)
	out := bufio.NewWriter(os.Stdout)

	for in.Scan() {
		line := bytes.TrimSpace(in.Bytes())
		if len(line) == 0 {
			continue
		}
		resp, err := c.do(http.MethodPost, "/v1/mcp", bytes.NewReader(line))
		if err != nil {
			return err
		}
		body, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if readErr != nil {
			return readErr
		}
		// 202 with no body: the message was a notification.
		if resp.StatusCode == http.StatusAccepted || len(bytes.TrimSpace(body)) == 0 {
			continue
		}
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("daemon rejected an MCP message with %d: %s", resp.StatusCode, bytes.TrimSpace(body))
		}
		// The daemon writes compact single-line JSON; stdio framing is
		// one message per line.
		out.Write(bytes.TrimSpace(body))
		out.WriteByte('\n')
		if err := out.Flush(); err != nil {
			return err
		}
	}
	return in.Err()
}
