.PHONY: build test clean inspect vendor

# voxgig/sekreto and voxgig/omni are sibling checkouts, not published
# crates, and they may sit anywhere. Link them under vendor/ so Cargo.toml
# can name fixed paths that work on any machine (the sekreto rust port's
# own pattern for omni).
SEKRETO := $(shell \
  for d in "$$SEKRETO_HOME" ../../sekreto ../../../sekreto /workspace/sekreto /home/user/sekreto; do \
    if [ -n "$$d" ] && [ -f "$$d/rust/Cargo.toml" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

vendor:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	mkdir -p vendor
	ln -sfn $(SEKRETO)/rust vendor/sekreto
	ln -sfn $(OMNI)/rust vendor/omni

build: vendor
	cargo build --release

test: vendor
	cargo test

clean:
	cargo clean
	rm -rf vendor

inspect:
	@cargo --version
	@echo "sekreto: $(SEKRETO)"
	@echo "omni:    $(OMNI)"
