.PHONY: build test vet run clean inspect

# voxgig/sekreto is a sibling checkout, not a published module, and it may
# sit anywhere. Find it, then use a go workspace to point imports at it -
# which keeps go.mod free of paths that only work on one machine. (The
# same convention station/go and sekreto/go use.)
#
# The proxy does not import sekreto YET - R2 (`resolve: proxy`, design
# §5.3) arrives in a later phase, when the proxy grows its own sekreto
# instance for proxy-side resolution (§8.3). The workspace is generated
# now so that adding the `require` then is a one-line go.mod change with
# no build-system work: a go.work `use` of a module nothing imports is
# harmless.
SEKRETO := $(shell \
  for d in "$$SEKRETO_HOME" ../../sekreto ../../../sekreto /workspace/sekreto /home/user/sekreto; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/sekreto.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

go.work:
	@test -n "$(SEKRETO)" || { echo "station/proxy: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	go work init . $(SEKRETO)/go

build: go.work
	go build ./...
	go build -o voxgig-station ./cmd/voxgig-station

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
