module github.com/voxgig/station/proxy

go 1.21

// R2 (design §5.3): the proxy holds the sekreto instance and the provider
// credentials, resolving through its OWN chain by its OWN mapping (§8.3).
// Resolved against the sibling checkout via the Makefile-generated
// go.work, the station/go convention.
require github.com/voxgig/sekreto/go v0.0.0
