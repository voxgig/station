.PHONY: build test clean inspect

# voxgig/omni and voxgig/sekreto are sibling checkouts, not published
# modules, and they may sit anywhere. Find them, then use a go workspace
# to point the imports at them - which keeps go.mod free of paths that
# only work on one machine. (The same convention sekreto/go uses.)
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

go.work:
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	go work init . $(OMNI)/go $(SEKRETO)/go

build: go.work
	go build ./...

# -count=1 disables the test cache. The spec is read at run time, so Go
# cannot see that it changed and would otherwise report a stale pass after
# spec/station.json is edited.
test: go.work
	go test -count=1 ./...

clean:
	go clean
	rm -rf go.work go.work.sum

inspect:
	@go version
	@echo "omni:    $(OMNI)"
	@echo "sekreto: $(SEKRETO)"
