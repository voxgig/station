module github.com/voxgig/station/go

// 1.23 because voxgig/struct's Go port declares it, and struct is a
// RUNTIME dependency here: validateConfig runs at Open(), not only
// under test (design §4, §9).
go 1.23

require (
	github.com/voxgig/sekreto/go v0.0.0
	github.com/voxgig/struct/go v0.0.0
)
