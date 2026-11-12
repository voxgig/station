.PHONY: build build-clean test vet run clean inspect go.work

# voxgig/sekreto is a sibling checkout, and so is voxgig/plugin, which
# sekreto's go module imports. Find them, then use a go workspace to point
# the imports at them - the station/go convention. go.mod names real
# versions as well, so the module also builds with no workspace at all:
# build-clean proves that.
SEKRETO := $(shell \
  for d in "$$SEKRETO_HOME" ../../sekreto ../../../sekreto /workspace/sekreto /home/user/sekreto; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/sekreto.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

PLUGIN := $(shell \
  for d in "$$PLUGIN_HOME" ../../plugin ../../../plugin /workspace/plugin /home/user/plugin; do \
    if [ -n "$$d" ] && [ -f "$$d/go/plugin/catalog.go" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# PHONY, as in station/go: a go.work left on disk from an earlier layout
# would otherwise look up to date.
go.work:
	@test -n "$(SEKRETO)" || { echo "station/proxy: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(PLUGIN)" || { echo "station/proxy: voxgig/plugin not found - set PLUGIN_HOME (sekreto needs it)" >&2; exit 1; }
	@rm -f go.work go.work.sum
	go work init . $(SEKRETO)/go $(PLUGIN)/go

build: go.work
	go build ./...
	go build -o voxgig-station ./cmd/voxgig-station

# As a consumer resolves it: go.mod and go.sum alone, no workspace.
build-clean:
	GOWORK=off go build ./...
	GOWORK=off go vet ./...

# -count=1 disables the test cache, matching the station/go convention.
test: go.work
	go test -count=1 ./...

vet: go.work
	go vet ./...

run: go.work
	go run ./cmd/voxgig-station run

clean:
	go clean
	rm -rf go.work go.work.sum voxgig-station

inspect:
	@go version
	@echo "sekreto: $(SEKRETO)"
	@echo "plugin: $(PLUGIN)"
