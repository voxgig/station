.PHONY: build build-clean test clean inspect go.work go.noomni.work

# voxgig/omni and voxgig/sekreto are sibling checkouts, not published
# modules, and they may sit anywhere. Find them, then use a go workspace
# to point the imports at them - which keeps go.mod free of paths that
# only work on one machine. (The same convention sekreto/go uses.)
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

# PHONY, and it has to be: go.work is gitignored but survives on a
# developer's disk, so a file target would leave a workspace written
# before the testutil module existed looking up to date - and `go test
# ./testutil/...` then fails with "directory prefix testutil does not
# contain modules listed in go.work". Regenerating is cheap; being
# stale is not.
go.work:
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@rm -f go.work go.work.sum
	go work init . ./testutil $(OMNI)/go $(SEKRETO)/go

build: go.work
	go build ./...

# Register 4.13 proof: the published module must build with NO omni checkout
# present. station's library genuinely depends on sekreto (design §10), so
# that one sibling still resolves - through a workspace naming ONLY sekreto,
# written to its own file (go.noomni.work, gitignored) so the everyday
# go.work, which names omni, cannot leak in. CI runs this before omni is
# fetched.
go.noomni.work:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@printf 'go 1.21\n\nuse (\n\t.\n\t%s/go\n)\n' '$(SEKRETO)' > go.noomni.work

build-clean: go.noomni.work
	GOWORK=$(abspath go.noomni.work) go build ./...
	GOWORK=$(abspath go.noomni.work) go test -count=1 ./...

# -count=1 disables the test cache. The spec is read at run time, so Go
# cannot see that it changed and would otherwise report a stale pass after
# spec/station.json is edited.
test: go.work
	go test -count=1 ./... ./testutil/...

clean:
	go clean
	rm -rf go.work go.work.sum go.noomni.work

inspect:
	@go version
	@echo "omni:    $(OMNI)"
	@echo "sekreto: $(SEKRETO)"
