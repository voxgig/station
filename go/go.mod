module github.com/voxgig/station/go

// 1.23 because voxgig/struct's Go port declares it, and struct is a
// RUNTIME dependency here: validateConfig runs at Open(), not only
// under test (design §4, §9).
go 1.23

// Real versions, so a consumer outside a go workspace resolves this module;
// the Makefile's go.work still points every one at a sibling checkout.
require (
	github.com/voxgig/sekreto/go v0.0.0-20260916220330-32b83acba90a
	github.com/voxgig/struct/go v0.1.6
)

require (
	github.com/voxgig/plugin/go v0.0.0-20260901203214-91f294b7a228 // indirect
	github.com/voxgig/struct/go/testutil v0.0.0-20261009084424-3ab807cc2ae7 // indirect
)
