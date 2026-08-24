.PHONY: build build-clean test clean inspect sync-shape go.work go.noomni.work

# voxgig/omni, voxgig/sekreto and voxgig/struct are sibling checkouts,
# not published modules, and they may sit anywhere. Find them, then use a
# go workspace to point the imports at them - which keeps go.mod free of
# paths that only work on one machine. (The same convention sekreto/go
# uses.)
#
# The conformance suite is a nested module, ./testutil, so that the
# published module never names omni: `go build ./...` here skips a nested
# module, and `go mod tidy` cannot resolve omni from the proxy and add it
# to the published dependency graph. (The convention voxgig/struct#89 set;
# omni register 4.13.) sekreto is different - the LIBRARY depends on it
# (design §10) - so it stays a require of this module. The cost of the
# nested module is that ./... no longer reaches the suite, so each target
# names it.
OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

SEKRETO := $(shell \
  for d in "$$SEKRETO_HOME" ../../sekreto ../../../sekreto /workspace/sekreto /home/user/sekreto; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/sekreto.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# voxgig/struct backs validateConfig (design §4, §9). Unlike omni it is a
# RUNTIME dependency - validateConfig runs at open(), not just under test -
# so it is a require of the PUBLISHED module and has to resolve for
# build-clean too. Found the same way as the other two siblings.
STRUCT := $(shell \
  for d in "$$STRUCT_HOME" ../../struct ../../../struct /workspace/struct /home/user/struct; do \
    if [ -n "$$d" ] && [ -f "$$d/go/voxgigstruct.go" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# PHONY, and it has to be: go.work is gitignored but survives on a
# developer's disk, so a file target would leave a workspace written
# before the testutil module existed looking up to date - and `go test
# ./testutil/...` then fails with "directory prefix testutil does not
# contain modules listed in go.work". Regenerating is cheap; being
# stale is not.
go.work:
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(STRUCT)" || { echo "station: voxgig/struct not found - set STRUCT_HOME" >&2; exit 1; }
	@rm -f go.work go.work.sum
	go work init . ./testutil $(OMNI)/go $(SEKRETO)/go $(STRUCT)/go

build: go.work
	go build ./...

# Register 4.13 proof: the published module must build with NO omni checkout
# present. station's library genuinely depends on sekreto (design §10) and
# on struct (design §4 - validateConfig runs at open()), so those two
# siblings still resolve - through a workspace naming ONLY them, written to
# its own file (go.noomni.work, gitignored) so the everyday go.work, which
# names omni, cannot leak in. CI runs this before omni is fetched.
go.noomni.work:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(STRUCT)" || { echo "station: voxgig/struct not found - set STRUCT_HOME" >&2; exit 1; }
	@printf 'go 1.23\n\nuse (\n\t.\n\t%s/go\n\t%s/go\n)\n' '$(SEKRETO)' '$(STRUCT)' > go.noomni.work

build-clean: go.noomni.work
	GOWORK=$(abspath go.noomni.work) go build ./...
	GOWORK=$(abspath go.noomni.work) go test -count=1 ./...

# -count=1 disables the test cache. The spec is read at run time, so Go
# cannot see that it changed and would otherwise report a stale pass after
# spec/station.json is edited.
test: go.work
	go test -count=1 ./... ./testutil/...

# The shape artifact is DATA (design §4.3), and spec/config-shape.json is
# the copy every port reads. Go publishes a compiled module that cannot
# see spec/ at run time - and validateConfig runs at open(), not just
# under test - so the package embeds a mirror of it. Re-run this after
# editing the spec; testutil/shape_test.go fails on drift.
sync-shape:
	cp ../spec/config-shape.json station/config-shape.json

clean:
	go clean
	rm -rf go.work go.work.sum go.noomni.work

inspect:
	@go version
	@echo "omni:    $(OMNI)"
	@echo "sekreto: $(SEKRETO)"
	@echo "struct:  $(STRUCT)"
