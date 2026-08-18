# station - per-language build/test drivers.
# Layout follows the sibling multi-port libraries (sekreto, omni):
# per-language directories, spec/ at the root, sdkgen-station/ holding
# the sdkgen feature package.
#
# test runs the ports whose toolchains are commonly present; each port
# also has its own Makefile or test script (see <lang>/README.md).

RUNNABLE = typescript javascript go python ruby php perl java rust c cpp

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

test-rust:
	cd rust && cargo test --offline

test-c:
	cd c && $(MAKE) test

test-cpp:
	cd cpp && $(MAKE) test

# Toolchain-gated ports (run where the toolchain exists):
test-csharp:
	cd csharp && $(MAKE) test

test-swift:
	cd swift && swift test

test-dart:
	cd dart && dart test

test-elixir:
	cd elixir && mix test

test-lua:
	cd lua && lua5.4 test/station.lua && lua5.4 test/conform.lua

build-typescript:
	cd typescript && npm run build

.PHONY: test build-typescript $(addprefix test-,$(RUNNABLE)) test-csharp test-swift test-dart test-elixir test-lua
