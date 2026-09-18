# Implementation rationale

Descriptors retain each feature's typed option defaults and transport role. Validation needs those defaults, and transport ordering needs the role; discarding them loses information already available from the SDK.

The proxy derives its host and origin allowlist from the actual bound address. Keep those checks at the HTTP boundary to protect against DNS rebinding.

Sources: [descriptor construction](go/station/descriptor.go), [proxy server](proxy/internal/daemon/server.go), [agent guide](AGENTS.md).
