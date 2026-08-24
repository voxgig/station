# station - C++ port. Header-only; zero-dependency tests (the omni cpp
# harness pattern); the conformance suite needs a sibling voxgig/omni
# checkout (or OMNI_HOME), and the library itself needs a sibling
# voxgig/struct checkout (or STRUCT_HOME).

CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O2

# voxgig/omni is a sibling checkout, not a published package.
OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# voxgig/struct backs validate_config (design station.md 4, 9). Unlike
# omni it is a RUNTIME dependency - validation runs at open(), not only
# under test - and C++ has no registry, so it is VENDORED: a generated
# C++ SDK already carries it beside this library's own feature/station/.
# In THIS checkout it is a sibling, found the way every port finds its
# siblings: $STRUCT_HOME, then a sibling directory, then two fixed
# fallbacks.
STRUCT := $(shell \
  for d in "$$STRUCT_HOME" ../../struct ../../../struct /workspace/struct /home/user/struct; do \
    if [ -n "$$d" ] && [ -f "$$d/cpp/src/voxgig_struct.hpp" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# struct is included with -isystem, not -I: it is a vendored dependency
# compiled as its own project ships it, and -Werror over somebody
# else's warnings is a build that breaks on their next release. (The C
# port's Makefile records the same rule in the other direction.)
STRUCT_INC = -isystem $(STRUCT)/cpp/src

.PHONY: build test clean inspect struct-check sync-shape

# Fail with the reason rather than a page of "voxgig_struct.hpp: No such
# file or directory".
struct-check:
	@if [ -z "$(STRUCT)" ]; then \
	  echo "station: voxgig/struct checkout not found - set STRUCT_HOME."; \
	  echo "  struct validates the config grammar at open() (design 4);"; \
	  echo "  a generated SDK vendors it, this checkout borrows a sibling."; \
	  echo "  git clone https://github.com/voxgig/struct ../../struct"; \
	  exit 1; \
	fi

build: struct-check
	mkdir -p build
	$(CXX) $(CXXFLAGS) $(STRUCT_INC) -o build/unit test/unit.cpp
	@if [ -z "$(OMNI)" ]; then \
	  echo "station: voxgig/omni not found - set OMNI_HOME"; exit 1; \
	fi
	$(CXX) $(CXXFLAGS) $(STRUCT_INC) -I$(OMNI)/cpp/src -o build/conform test/conform.cpp

test: build
	./build/unit
	./build/conform

# The shape artifact is DATA (design 4.3) and spec/config-shape.json is
# the copy every port reads; this library is vendored into a compiled
# SDK that cannot see spec/ at run time, so the header carries a MIRROR
# of it. Re-run after editing the spec - test/unit.cpp's shape check
# fails on drift.
sync-shape:
	python3 tools/sync-shape.py

clean:
	rm -rf build

inspect:
	@$(CXX) --version | head -1
	@echo "omni:   $(OMNI)"
	@echo "struct: $(STRUCT)"
