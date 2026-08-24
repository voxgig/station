# station - per-language build/test drivers.
# Layout follows the sibling multi-port libraries (sekreto, omni):
# per-language directories, spec/ at the root, sdkgen-station/ holding
# the sdkgen feature package.
#
# test runs the ports whose toolchains are commonly present; each port
# also has its own Makefile or test script (see <lang>/README.md).

RUNNABLE = typescript javascript go python ruby php perl java rust c cpp csharp swift dart elixir lua

test: $(addprefix test-,$(RUNNABLE))

test-typescript:
	cd typescript && npm test

test-javascript:
	cd javascript && npm test

test-go:
	cd go && $(MAKE) test

test-python:
	cd python && $(MAKE) test

test-ruby:
	cd ruby && ruby test/station_test.rb && ruby test/conform_test.rb && ruby test/quickstart_test.rb

test-php:
	cd php && php test/run.php

test-perl:
	cd perl && $(MAKE) test

test-java:
	cd java && $(MAKE) test

# via the port Makefile: rust's `test` depends on `vendor`, which links
# vendor/sekreto and vendor/omni to the sibling checkouts that Cargo.toml
# names as path dependencies. A bare `cargo test` cannot resolve them.
test-rust:
	cd rust && $(MAKE) test

test-c:
	cd c && $(MAKE) test

test-cpp:
	cd cpp && $(MAKE) test

# Toolchain-gated ports (run where the toolchain exists):
test-csharp:
	cd csharp && $(MAKE) test

# via the port Makefile, for the same reason as rust: `test` depends on
# `vendor`, which links vendor/omni. swift/vendor is not tracked.
test-swift:
	cd swift && $(MAKE) test

test-dart:
	cd dart && dart test

test-elixir:
	cd elixir && mix test

test-lua:
	cd lua && lua5.4 test/station.lua && lua5.4 test/conform.lua

build-typescript:
	cd typescript && npm run build

# C4a/C4b (plugin/doc/plan/contracts.md): plugin's `ref`/`config` and
# `lifecycle`/`order` corpus sections, run against station's OWN
# implementation from a sibling voxgig/plugin checkout (or $PLUGIN_HOME).
# STATION_REQUIRE_C4 makes a missing checkout a failure rather than a
# skip - this target exists to run that lane deliberately.
test-c4:
	cd typescript && STATION_REQUIRE_C4=1 npm run test-some --pattern=c4-plugin

# spec/config-shape.json is the artifact every port reads; the
# TypeScript port ships a mirror of it because package.json ships
# dist/src only and validateConfig runs at open(), not just under test.
# typescript/test/shape.test.ts fails on drift.
sync-shape:
	python3 tools/sync-shape.py

.PHONY: test build-typescript sync-shape test-c4 $(addprefix test-,$(RUNNABLE)) test-csharp test-swift test-dart test-elixir test-lua
