.PHONY: build test clean inspect vendor

# voxgig/omni (the conformance runner, test-only) is a sibling checkout,
# not a published package, and it may sit anywhere. Link it under vendor/
# so Package.swift can name a fixed path that works on any machine (the
# rust port's scheme). There is no sekreto link: no Swift sekreto port
# exists, so this library is env-only for secrets (station design 2.2)
# and takes no dependency at all.
OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

vendor:
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	mkdir -p vendor
	ln -sfn $(OMNI)/swift vendor/omni

build: vendor
	swift build

test: vendor
	swift test

clean:
	rm -rf .build vendor

inspect:
	@swift --version | head -1
	@echo "omni: $(OMNI)"
