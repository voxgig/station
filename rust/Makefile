.PHONY: build build-clean test clean inspect vendor vendor-sekreto

# voxgig/sekreto and voxgig/omni are sibling checkouts, not published
# crates, and they may sit anywhere. Link them under vendor/ so the
# manifests can name fixed paths that work on any machine (the sekreto
# rust port's own pattern for omni) - Cargo path dependencies are literal
# and cannot read $SEKRETO_HOME / $OMNI_HOME.
#
# The conformance suite is a separate package (`corpus/`) so that omni
# stays out of the library's manifest entirely: Cargo resolves
# dev-dependencies even for `cargo build`, so a dev-dependency here broke
# a checkout with no omni beside it. (Omni register 4.13; the shape
# voxgig/struct#97 set.) sekreto is different - the LIBRARY depends on it
# (design §10) - so vendor/sekreto stays in Cargo.toml.
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

vendor-sekreto:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	mkdir -p vendor
	ln -sfn $(SEKRETO)/rust vendor/sekreto

vendor: vendor-sekreto
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	ln -sfn $(OMNI)/rust vendor/omni

build: vendor-sekreto
	cargo build --release

# Register 4.13 proof: the library (every target of it - the unit tests
# included) must build with NO omni checkout and NO vendor/omni link. Only
# sekreto is linked, because the library genuinely depends on it (design
# §10). CI runs this before omni is fetched.
build-clean: vendor-sekreto
	cargo build --all-targets

test: vendor
	cargo test
	cd corpus && cargo test

clean:
	cargo clean
	cd corpus && cargo clean
	rm -rf vendor

inspect:
	@cargo --version
	@echo "sekreto: $(SEKRETO)"
	@echo "omni:    $(OMNI)"
