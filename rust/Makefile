.PHONY: build build-clean test clean inspect sync-shape vendor vendor-runtime

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

# voxgig/struct backs validateConfig (design §4, §9). Unlike omni it is a
# RUNTIME dependency - validateConfig runs at open(), not only under test -
# so it is a dependency of the PUBLISHED crate and has to resolve for
# build-clean too. Found by the same convention as the other two siblings:
# $STRUCT_HOME, then a sibling checkout, then two fixed fallbacks.
STRUCT := $(shell \
  for d in "$$STRUCT_HOME" ../../struct ../../../struct /workspace/struct /home/user/struct; do \
    if [ -n "$$d" ] && [ -f "$$d/rust/Cargo.toml" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# The two the LIBRARY itself needs: sekreto resolves secrets (design §10)
# and struct validates the config grammar (§4). omni is the suite's, and
# only the suite's.
vendor-runtime:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(STRUCT)" || { echo "station: voxgig/struct not found - set STRUCT_HOME" >&2; exit 1; }
	mkdir -p vendor
	ln -sfn $(SEKRETO)/rust vendor/sekreto
	ln -sfn $(STRUCT)/rust vendor/struct

vendor: vendor-runtime
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	ln -sfn $(OMNI)/rust vendor/omni

build: vendor-runtime
	cargo build --release

# Register 4.13 proof: the library (every target of it - the unit tests
# included) must build with NO omni checkout and NO vendor/omni link. Only
# sekreto and struct are linked, because the library genuinely depends on
# both - sekreto resolves secrets (design §10) and struct validates the
# config grammar at open() (design §4). CI runs this before omni is
# fetched.
build-clean: vendor-runtime
	cargo build --all-targets

test: vendor
	cargo test
	cd corpus && cargo test

# The shape artifact is DATA (design §4.3), and spec/config-shape.json is
# the copy every port reads. This crate is published and compiled: it
# cannot see spec/ at run time, and validateConfig runs at open() rather
# than only under test - so src/config-shape.json is a MIRROR, embedded
# with include_str!. Re-run this after editing the spec;
# tests/unit.rs::config_shape_mirror_matches_the_spec fails on drift.
sync-shape:
	cp ../spec/config-shape.json src/config-shape.json

clean:
	cargo clean
	cd corpus && cargo clean
	rm -rf vendor

inspect:
	@cargo --version
	@echo "sekreto: $(SEKRETO)"
	@echo "struct:  $(STRUCT)"
	@echo "omni:    $(OMNI)"
