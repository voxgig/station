# station

`voxgig/station` — one control surface for outbound integrations.

Station sits between an application and all of its generated
[sdkgen](https://github.com/voxgig/sdkgen) SDKs. Each SDK registers with
a local station as a plugin, making station the single place where
outbound integrations are configured, credentialed, observed, policed,
and debugged — for the developer and for an AI agent working on or
through the application.

Secrets are brokered through
[voxgig/sekreto](https://github.com/voxgig/sekreto); application code
names a secret, never a value.

## Status

Proposal. Nothing is implemented yet — the design is the deliverable at
this stage.

- [`docs/design/station.md`](./docs/design/station.md) — the full design:
  the plugin contract, the descriptor, secret placement, observability
  and debugging, the MCP agent surface, the wire protocol and companion
  proxy, the sdkgen integration, and delivery phasing.
