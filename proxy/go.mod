module github.com/voxgig/station/proxy

go 1.21

// R2 (design §5.3): the proxy holds the sekreto instance and the provider
// credentials, resolving through its OWN chain by its OWN mapping (§8.3).
// Real versions, so the module resolves outside a go workspace; the
// Makefile's go.work still points each one at a sibling checkout.
require github.com/voxgig/sekreto/go v0.0.0-20260916220330-32b83acba90a

require github.com/voxgig/plugin/go v0.0.0-20260901203214-91f294b7a228 // indirect
