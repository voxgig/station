# station - C++ port. Header-only; zero-dependency tests (the omni cpp
# harness pattern); the conformance suite needs a sibling voxgig/omni
# checkout (or OMNI_HOME).

CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O2

# voxgig/omni is a sibling checkout, not a published package.
OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

.PHONY: build test clean inspect

build:
	mkdir -p build
	$(CXX) $(CXXFLAGS) -o build/unit test/unit.cpp
	@if [ -z "$(OMNI)" ]; then \
	  echo "station: voxgig/omni not found - set OMNI_HOME"; exit 1; \
	fi
	$(CXX) $(CXXFLAGS) -I$(OMNI)/cpp/src -o build/conform test/conform.cpp

test: build
	./build/unit
	./build/conform

clean:
	rm -rf build

inspect:
	@$(CXX) --version | head -1
	@echo "omni: $(OMNI)"
