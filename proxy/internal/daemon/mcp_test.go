package daemon

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- MCP wire helpers ---------------------------------------------------

// rpc posts one JSON-RPC message to /v1/mcp and decodes the response.
func rpc(t *testing.T, ts *httptest.Server, id int, method string, params any) map[string]any {
	t.Helper()
	msg := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		msg["params"] = params
	}
	body, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	resp := call(t, ts, http.MethodPost, "/v1/mcp", string(body), nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("mcp status = %d", resp.StatusCode)
	}
	return decode(t, resp)
}

// agentTool calls one §7 tool and returns its decoded JSON payload plus
// the isError flag.
func agentTool(t *testing.T, ts *httptest.Server, name string, args any) (map[string]any, bool) {
	t.Helper()
	m := rpc(t, ts, 42, "tools/call", map[string]any{"name": name, "arguments": args})
	if e, is := m["error"].(map[string]any); is {
		t.Fatalf("tools/call %s: protocol error %v", name, e)
	}
	result, _ := m["result"].(map[string]any)
	content, _ := result["content"].([]any)
	if len(content) == 0 {
		t.Fatalf("tools/call %s: no content in %v", name, result)
	}
	text, _ := content[0].(map[string]any)["text"].(string)
	var payload map[string]any
	if err := json.Unmarshal([]byte(text), &payload); err != nil {
		t.Fatalf("tools/call %s: content is not JSON: %q", name, text)
	}
	isError, _ := result["isError"].(bool)
	return payload, isError
}

// toolErrCode digs the §14 code out of an isError tool payload.
func toolErrCode(t *testing.T, payload map[string]any) (code string, candidates []any) {
	t.Helper()
	e, _ := payload["error"].(map[string]any)
	if e == nil {
		t.Fatalf("tool error payload missing {error:{...}}: %v", payload)
	}
	code, _ = e["code"].(string)
	candidates, _ = e["candidates"].([]any)
	return code, candidates
}

// fullDescriptor is a §4-shaped descriptor with an entity/op map, the
// raw material for integrations/describe/call.
func fullDescriptor(base string) string {
	return fmt.Sprintf(`{"station":1,"name":"Solardemo","slug":"voxgig-solardemo","base":%q,
	  "auth":{"active":true,"prefix":"Bearer"},
	  "entities":{"planet":{
	    "fields":{"name":{"kind":"string","required":true},"mass":{"kind":"number"}},
	    "ops":{"list":{"points":[{"method":"GET","path":"/planet"}]},
	           "load":{"points":[{"method":"GET","path":"/planet/{id}"}]},
	           "create":{"points":[{"method":"POST","path":"/planet"}]}}}}}`, base)
}

func registerDescriptor(t *testing.T, ts *httptest.Server, instance string, descriptor string) string {
	t.Helper()
	body := fmt.Sprintf(`{"descriptor":%s,"process":{"pid":7,"lang":"go","app":"agent-test"},"instance":%q}`,
		descriptor, instance)
	resp := call(t, ts, http.MethodPost, "/v1/register", body, nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register: %d", resp.StatusCode)
	}
	session, _ := decode(t, resp)["session"].(string)
	return session
}

// --- §12: the agent transcript -----------------------------------------

// TestAgentTranscript walks §12's "agent operating the app's
// integrations" transcript against the daemon through the MCP surface,
// as far as v1-core backs it, with named skips for the later phases.
func TestAgentTranscript(t *testing.T) {
	up := newUpstream(t)
	cfgPath := stationJSONFor(t, `"127.0.0.1"`, "proxy", "full")
	ts, srv := newTestProxyServer(t, func(c *Config) {
		c.StationConfigPath = cfgPath
	})
	if resp := call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, ""); resp.StatusCode != http.StatusOK {
		t.Fatalf("approve: %d", resp.StatusCode)
	}
	registerDescriptor(t, ts, "voxgig-solardemo", fullDescriptor(up.ts.URL))

	// The upstream echoes the injected credential back - the §7 caveat
	// the output scrub exists for.
	up.respond = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"planets":["mercury","venus"],"debug_auth":%q}`,
			r.Header.Get("Authorization"))
	}

	t.Run("initialize", func(t *testing.T) {
		m := rpc(t, ts, 1, "initialize", map[string]any{
			"protocolVersion": "2025-06-18",
			"capabilities":    map[string]any{},
			"clientInfo":      map[string]any{"name": "test-host", "version": "0"},
		})
		result := m["result"].(map[string]any)
		if result["protocolVersion"] != "2025-06-18" {
			t.Errorf("protocolVersion = %v", result["protocolVersion"])
		}
		info := result["serverInfo"].(map[string]any)
		if info["name"] != "voxgig-station" {
			t.Errorf("serverInfo.name = %v", info["name"])
		}
		if instructions, _ := result["instructions"].(string); !strings.Contains(instructions, "external data") {
			t.Errorf("instructions should state the §7 external-data rule, got %q", instructions)
		}
		// The initialized notification expects no response.
		resp := call(t, ts, http.MethodPost, "/v1/mcp",
			`{"jsonrpc":"2.0","method":"notifications/initialized"}`, nil, "")
		if resp.StatusCode != http.StatusAccepted {
			t.Errorf("notification status = %d, want 202", resp.StatusCode)
		}
	})

	t.Run("tools list: the eight, station-prefixed", func(t *testing.T) {
		m := rpc(t, ts, 2, "tools/list", nil)
		tools := m["result"].(map[string]any)["tools"].([]any)
		if len(tools) != 8 {
			t.Fatalf("tools = %d, want 8", len(tools))
		}
		names := map[string]bool{}
		for _, tool := range tools {
			tm := tool.(map[string]any)
			name := tm["name"].(string)
			names[name] = true
			if !strings.HasPrefix(name, "station_") {
				t.Errorf("tool %q not station-prefixed", name)
			}
			if tm["inputSchema"] == nil {
				t.Errorf("tool %q has no inputSchema", name)
			}
		}
		for _, want := range []string{"station_status", "station_integrations", "station_describe",
			"station_call", "station_traffic", "station_replay", "station_secrets", "station_policy"} {
			if !names[want] {
				t.Errorf("missing tool %q", want)
			}
		}
	})

	t.Run("station_status: healthy, gates visible, rung reported", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_status", nil)
		if isErr || payload["ok"] != true {
			t.Fatalf("status payload = %v", payload)
		}
		agent := payload["agent"].(map[string]any)
		if agent["read"] != true || agent["write"] != false {
			t.Errorf("agent gates = %v, want read on, write off (§7 local defaults)", agent)
		}
		plugins := payload["plugins"].([]any)
		if len(plugins) != 1 {
			t.Fatalf("plugins = %v", plugins)
		}
		pv := plugins[0].(map[string]any)
		if pv["rung"] != "R2" || pv["resolve"] != "proxy" || pv["state"] != StateApproved {
			t.Errorf("plugin view = %v, want approved R2 proxy", pv)
		}
		resolution := payload["secretResolution"].(map[string]any)
		if got, _ := resolution["voxgig-solardemo"].(string); got != "resolved by memory" {
			t.Errorf("secretResolution = %q, want resolved by memory", got)
		}
	})

	t.Run("station_integrations: one call answers what can I call", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_integrations", nil)
		if isErr {
			t.Fatalf("payload = %v", payload)
		}
		items := payload["integrations"].([]any)
		if len(items) != 1 {
			t.Fatalf("integrations = %v", items)
		}
		item := items[0].(map[string]any)
		if item["plugin"] != "voxgig-solardemo" || item["api"] != "voxgig-solardemo" {
			t.Errorf("item identity = %v", item)
		}
		ops := item["entities"].(map[string]any)["planet"].([]any)
		if len(ops) != 3 || ops[0] != "create" || ops[1] != "list" || ops[2] != "load" {
			t.Errorf("planet ops = %v, want [create list load]", ops)
		}
	})

	var callBody string
	t.Run("station_call: read op, case-insensitive, injected, scrubbed", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "VOXGIG-SOLARDEMO", "entity": "Planet", "op": "LIST",
		})
		if isErr {
			t.Fatalf("call errored: %v", payload)
		}
		canonical := payload["canonical"].(map[string]any)
		if canonical["plugin"] != "voxgig-solardemo" || canonical["entity"] != "planet" || canonical["op"] != "list" {
			t.Errorf("canonical echo = %v (§7: canonical form echoed back)", canonical)
		}
		if payload["status"] != float64(200) {
			t.Errorf("status = %v", payload["status"])
		}
		// The synthesized request went to the canonical point with the
		// injected credential (§7: same policy/injection/capture path).
		req := up.last(t)
		if req.Method != "GET" || req.Path != "/planet" {
			t.Errorf("upstream saw %s %s, want GET /planet", req.Method, req.Path)
		}
		if got := req.Headers.Get("Authorization"); got != "Bearer "+testSecret {
			t.Errorf("upstream Authorization = %q", got)
		}
		// The upstream echoed the credential; the tool result must not
		// carry it (§7 output rule).
		callBody, _ = payload["body"].(string)
		if strings.Contains(callBody, testSecret) {
			t.Fatal("tool output contains the injected secret")
		}
		if !strings.Contains(callBody, redactedMarker) {
			t.Errorf("expected the redaction marker in the echoed body, got %q", callBody)
		}
		if !strings.Contains(callBody, "mercury") {
			t.Errorf("expected upstream data in the body, got %q", callBody)
		}
		if payload["contentOrigin"] != "upstream-external" {
			t.Errorf("contentOrigin = %v (§7: results labeled external data)", payload["contentOrigin"])
		}
	})

	t.Run("station_call: load with path parameter", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "load",
			"query": map[string]any{"id": 42, "expand": "moons"},
		})
		if isErr {
			t.Fatalf("call errored: %v", payload)
		}
		req := up.last(t)
		if req.Path != "/planet/42" {
			t.Errorf("upstream path = %q, want /planet/42", req.Path)
		}
	})

	t.Run("wrong names return candidates", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planets", "op": "list",
		})
		if !isErr {
			t.Fatal("expected an error for a wrong entity name")
		}
		code, candidates := toolErrCode(t, payload)
		if code != CodeNoEntity {
			t.Errorf("code = %q, want %q", code, CodeNoEntity)
		}
		if len(candidates) != 1 || candidates[0] != "planet" {
			t.Errorf("candidates = %v, want [planet] (§7)", candidates)
		}

		payload, isErr = agentTool(t, ts, "station_call", map[string]any{
			"plugin": "nope", "entity": "planet", "op": "list",
		})
		code, candidates = toolErrCode(t, payload)
		if !isErr || code != CodeNoPlugin || len(candidates) == 0 {
			t.Errorf("unknown plugin: isErr=%v code=%q candidates=%v", isErr, code, candidates)
		}

		payload, isErr = agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "destroy",
		})
		code, candidates = toolErrCode(t, payload)
		if !isErr || code != CodeNoOp || len(candidates) != 3 {
			t.Errorf("unknown op: isErr=%v code=%q candidates=%v", isErr, code, candidates)
		}
	})

	t.Run("station_traffic: what actually happened, redacted", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_traffic", map[string]any{
			"plugin": "voxgig-solardemo", "limit": 10,
		})
		if isErr {
			t.Fatalf("traffic errored: %v", payload)
		}
		captures := payload["captures"].([]any)
		if len(captures) < 2 {
			t.Fatalf("captures = %d, want the agent calls", len(captures))
		}
		text, _ := json.Marshal(payload)
		if strings.Contains(string(text), testSecret) {
			t.Fatal("traffic output contains the secret")
		}
		if payload["contentOrigin"] != "upstream-external" {
			t.Errorf("contentOrigin = %v", payload["contentOrigin"])
		}
		if _, has := payload["next"]; !has {
			t.Error("cursor-based output should carry next")
		}
	})

	t.Run("station_call: mutating op refused without --agent-write", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "create",
			"data": map[string]any{"name": "pluto"},
		})
		if !isErr {
			t.Fatal("mutating call must be refused (writes are a policy grant, not a default - §12)")
		}
		code, _ := toolErrCode(t, payload)
		if code != CodeAgentAllow {
			t.Errorf("code = %q, want %q", code, CodeAgentAllow)
		}
	})

	t.Run("station_describe: fields and requiredness", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_describe", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "PLANET",
		})
		if isErr {
			t.Fatalf("describe errored: %v", payload)
		}
		if payload["entity"] != "planet" {
			t.Errorf("canonical entity = %v", payload["entity"])
		}
		fields := payload["fields"].(map[string]any)
		name := fields["name"].(map[string]any)
		if name["required"] != true {
			t.Errorf("fields.name = %v, want requiredness surfaced", name)
		}
		if _, has := payload["ops"].(map[string]any)["load"]; !has {
			t.Error("ops should include load with its points")
		}
	})

	t.Run("station_policy: effective view", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_policy", map[string]any{"plugin": "voxgig-solardemo"})
		if isErr {
			t.Fatalf("policy errored: %v", payload)
		}
		if payload["state"] != StateApproved || payload["agentWrite"] != false {
			t.Errorf("policy view = %v", payload)
		}
	})

	t.Run("station_secrets: names and placement, never values", func(t *testing.T) {
		payload, isErr := agentTool(t, ts, "station_secrets", nil)
		if isErr {
			t.Fatalf("secrets errored: %v", payload)
		}
		items := payload["secrets"].([]any)
		item := items[0].(map[string]any)
		if item["secret"] != "voxgig_solardemo.apikey" {
			t.Errorf("secret name = %v", item["secret"])
		}
		if got, _ := item["resolution"].(string); got != "resolved by memory" {
			t.Errorf("resolution = %q (which store answered, §7)", got)
		}
		if placement, _ := item["placement"].(string); !strings.Contains(placement, "R2") {
			t.Errorf("placement = %q", placement)
		}
		text, _ := json.Marshal(payload)
		if strings.Contains(string(text), testSecret) {
			t.Fatal("station_secrets emitted a value")
		}
	})

	t.Run("station_replay: gates real, execution honest", func(t *testing.T) {
		// Find the read capture of the agent's list call.
		traffic, _ := agentTool(t, ts, "station_traffic", map[string]any{"limit": 100})
		var readID float64
		for _, c := range traffic["captures"].([]any) {
			cm := c.(map[string]any)
			if cm["reqMethod"] == "GET" && cm["replayable"] == true {
				readID = cm["id"].(float64)
			}
		}
		if readID == 0 {
			t.Fatal("no replayable GET capture found")
		}
		payload, isErr := agentTool(t, ts, "station_replay", map[string]any{"id": readID})
		if isErr {
			t.Fatalf("replay of a read capture errored: %v", payload)
		}
		if payload["replay"] != "unavailable" {
			t.Errorf("v1 replay = %v, want the honest unavailable report", payload["replay"])
		}
		if reason, _ := payload["reason"].(string); !strings.Contains(reason, "Phase 2") {
			t.Errorf("reason = %q, want the §17 phase named", reason)
		}

		// An unknown capture id.
		payload, isErr = agentTool(t, ts, "station_replay", map[string]any{"id": 99999})
		code, _ := toolErrCode(t, payload)
		if !isErr || code != CodeNoCapture {
			t.Errorf("unknown id: isErr=%v code=%q", isErr, code)
		}
	})

	t.Run("whole-surface guarantee: no secret anywhere", func(t *testing.T) {
		if strings.Contains(srv.captures.DumpForScan(), testSecret) {
			t.Fatal("the capture store holds the secret")
		}
	})

	// Named skips: what the transcript needs from later phases.
	t.Run("station_replay executes the request", func(t *testing.T) {
		t.Skip("replay engine ships with the record/replay phase (design §17 Phase 2)")
	})
	t.Run("station_call action routes", func(t *testing.T) {
		t.Skip("multi-point $action ops are an open question (design §18); v1 targets the canonical point")
	})
	t.Run("remote-mode agent.read default off", func(t *testing.T) {
		t.Skip("remote proxy mode is Phase 3 (design §8.4); local default is read-on")
	})
}

// TestAgentWriteGates: the two write halves - daemon flag AND per-
// instance policy - and the open path when both are granted (§7, §16).
func TestAgentWriteGates(t *testing.T) {
	up := newUpstream(t)

	// Config granting agent.write to the instance.
	text := fmt.Sprintf(`{"station":1,"profiles":{"default":{
	  "secrets":{"providers":[{"kind":"memory","values":{"VOXGIG_SOLARDEMO_APIKEY":%q}}]},
	  "sdk":{"voxgig-solardemo":{"resolve":"proxy","capture":"meta",
	    "policy":{"hosts":["127.0.0.1"]},"agent":{"write":true}}}}}}`, testSecret)
	cfgPath := filepath.Join(t.TempDir(), "station.json")
	if err := os.WriteFile(cfgPath, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Run("policy opt-in without the daemon flag still refuses", func(t *testing.T) {
		ts, _ := newTestProxyServer(t, func(c *Config) { c.StationConfigPath = cfgPath })
		call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, "")
		registerDescriptor(t, ts, "voxgig-solardemo", fullDescriptor(up.ts.URL))
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "create",
			"data": map[string]any{"name": "pluto"},
		})
		code, _ := toolErrCode(t, payload)
		if !isErr || code != CodeAgentAllow {
			t.Fatalf("isErr=%v code=%q, want station_agent_allow (daemon half closed)", isErr, code)
		}
	})

	t.Run("both gates open: the write proceeds and is captured", func(t *testing.T) {
		ts, srv := newTestProxyServer(t, func(c *Config) {
			c.StationConfigPath = cfgPath
			c.AgentWrite = true
		})
		call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, "")
		registerDescriptor(t, ts, "voxgig-solardemo", fullDescriptor(up.ts.URL))
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "create",
			"data": map[string]any{"name": "pluto"},
		})
		if isErr {
			t.Fatalf("granted write errored: %v", payload)
		}
		req := up.last(t)
		if req.Method != "POST" || req.Path != "/planet" || !strings.Contains(req.Body, "pluto") {
			t.Errorf("upstream saw %s %s body %q", req.Method, req.Path, req.Body)
		}
		if got := req.Headers.Get("Authorization"); got != "Bearer "+testSecret {
			t.Errorf("upstream Authorization = %q", got)
		}
		if srv.captures.Stats().Total < 1 {
			t.Error("the agent write was not captured")
		}
	})

	t.Run("daemon flag without policy opt-in still refuses", func(t *testing.T) {
		plain := stationJSONFor(t, `"127.0.0.1"`, "proxy", "meta") // no agent.write
		ts, _ := newTestProxyServer(t, func(c *Config) {
			c.StationConfigPath = plain
			c.AgentWrite = true
		})
		call(t, ts, http.MethodPost, "/v1/approve/voxgig-solardemo", "", nil, "")
		registerDescriptor(t, ts, "voxgig-solardemo", fullDescriptor(up.ts.URL))
		payload, isErr := agentTool(t, ts, "station_call", map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "create",
		})
		code, _ := toolErrCode(t, payload)
		if !isErr || code != CodeAgentAllow {
			t.Fatalf("isErr=%v code=%q, want station_agent_allow (policy half closed)", isErr, code)
		}
	})
}

// TestAgentReadGate: the §7 agent.read knob turned off refuses the
// data-bearing tools while status stays reachable, and the gates are
// visible in status.
func TestAgentReadGate(t *testing.T) {
	up := newUpstream(t)
	ts, _ := newTestProxyServer(t, func(c *Config) { c.AgentReadDisabled = true })
	registerDescriptor(t, ts, "voxgig-solardemo", fullDescriptor(up.ts.URL))

	for _, tool := range []string{"station_call", "station_traffic", "station_replay"} {
		payload, isErr := agentTool(t, ts, tool, map[string]any{
			"plugin": "voxgig-solardemo", "entity": "planet", "op": "list", "id": 1,
		})
		code, _ := toolErrCode(t, payload)
		if !isErr || code != CodeAgentAllow {
			t.Errorf("%s: isErr=%v code=%q, want station_agent_allow", tool, isErr, code)
		}
	}

	payload, isErr := agentTool(t, ts, "station_status", nil)
	if isErr {
		t.Fatalf("status should stay reachable: %v", payload)
	}
	if agent := payload["agent"].(map[string]any); agent["read"] != false {
		t.Errorf("status agent.read = %v, want false (visible gate)", agent["read"])
	}
}

// TestMCPWire: protocol-level details of the minimal server.
func TestMCPWire(t *testing.T) {
	ts := newTestProxy(t, nil)

	t.Run("auth still required", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/mcp",
			`{"jsonrpc":"2.0","id":1,"method":"ping"}`,
			map[string]string{"Authorization": ""}, "")
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401 (§8.1: token on every request)", resp.StatusCode)
		}
	})

	t.Run("host check still applies", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/mcp",
			`{"jsonrpc":"2.0","id":1,"method":"ping"}`, nil, "evil.example.com")
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", resp.StatusCode)
		}
	})

	t.Run("no Station-Protocol needed", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/mcp",
			`{"jsonrpc":"2.0","id":1,"method":"ping"}`,
			map[string]string{"Station-Protocol": ""}, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200 (MCP versions itself in initialize)", resp.StatusCode)
		}
	})

	t.Run("unknown method", func(t *testing.T) {
		m := rpc(t, ts, 7, "resources/list", nil)
		e := m["error"].(map[string]any)
		if e["code"] != float64(-32601) {
			t.Errorf("error = %v, want -32601", e)
		}
	})

	t.Run("parse error", func(t *testing.T) {
		resp := call(t, ts, http.MethodPost, "/v1/mcp", "{not json", nil, "")
		m := decode(t, resp)
		e := m["error"].(map[string]any)
		if e["code"] != float64(-32700) {
			t.Errorf("error = %v, want -32700", e)
		}
	})

	t.Run("unknown tool", func(t *testing.T) {
		m := rpc(t, ts, 8, "tools/call", map[string]any{"name": "station_nope"})
		e := m["error"].(map[string]any)
		if e["code"] != float64(-32602) {
			t.Errorf("error = %v, want -32602", e)
		}
	})
}
