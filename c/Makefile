# station - C port. Standalone unit tests plus the shared conformance
# corpus (spec/station.json) through the sibling voxgig/omni C runner
# (or OMNI_HOME).

CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2
LDLIBS ?= -lm

STATION_SRC = src/voxgig_station.c src/voxgig_station_shape.c \
  src/voxgig_station_feature.c src/voxgig_station_factory.c

OMNI_HOME ?= $(abspath ../../omni)
OMNI_SRC = $(OMNI_HOME)/c/src/json.c $(OMNI_HOME)/c/src/util.c $(OMNI_HOME)/c/src/runner.c
OMNI_OBJ = $(addprefix build/omni/,$(notdir $(OMNI_SRC:.c=.o)))

# voxgig/struct backs vxstn_validate_config (design station.md 4, 9).
# Unlike omni it is a RUNTIME dependency - validation runs at open(),
# not only under test - and C has no registry, so it is VENDORED: a
# generated C SDK already carries it at `utility/struct/` beside this
# library's own `feature/station/` (sdkgen-station .sdk/tm/c, the
# precedent VENDORED.md names). In THIS checkout it is a sibling, found
# the way every port finds its siblings: $STRUCT_HOME, then a sibling
# directory, then two fixed fallbacks.
STRUCT_DIR := $(shell \
  for d in "$$STRUCT_HOME" ../../struct ../../../struct /workspace/struct /home/user/struct; do \
    if [ -n "$$d" ] && [ -f "$$d/c/src/voxgig_struct.h" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)
STRUCT_SRC = $(wildcard $(STRUCT_DIR)/c/src/*.c)
STRUCT_OBJ = $(addprefix build/struct/,$(notdir $(STRUCT_SRC:.c=.o)))

# struct's own flags, not this port's: it is a vendored dependency
# compiled as its own project ships it, and -Werror over somebody
# else's warnings is a build that breaks on their next release.
STRUCT_CFLAGS = -std=c11 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE -O2

.PHONY: build test clean inspect sync-shape struct-check

# Fail with the reason rather than a page of "voxgig_struct.h: No such
# file or directory".
struct-check:
	@if [ -z "$(STRUCT_DIR)" ]; then \
	  echo "station: voxgig/struct checkout not found - set STRUCT_HOME."; \
	  echo "  struct validates the config grammar at open() (design 4);"; \
	  echo "  a generated SDK vendors it, this checkout borrows a sibling."; \
	  echo "  git clone https://github.com/voxgig/struct ../../struct"; \
	  exit 1; \
	fi

# Each dependency is compiled on ITS OWN include path, never with
# `-I src` or with another dependency's. struct ships `src/regex.h` and
# omni's util.c does `#include <regex.h>` wanting POSIX's: one shared
# command line put struct's on the angle-bracket search path and
# regex_t stopped existing. (The same shadowing struct's own Makefile
# records, in the other direction.)
build/struct/%.o: $(STRUCT_DIR)/c/src/%.c
	@mkdir -p build/struct
	$(CC) -c $< $(STRUCT_CFLAGS) -I $(STRUCT_DIR)/c/src -o $@

build/omni/%.o: $(OMNI_HOME)/c/src/%.c
	@mkdir -p build/omni
	$(CC) -c $< $(CFLAGS) -I $(OMNI_HOME)/c/src -o $@

build: struct-check $(STRUCT_OBJ) $(OMNI_OBJ)
	mkdir -p build
	$(CC) $(CFLAGS) -I $(STRUCT_DIR)/c/src -o build/unit \
	  $(STATION_SRC) $(STRUCT_OBJ) test/unit.c $(LDLIBS)
	$(CC) $(CFLAGS) -I $(STRUCT_DIR)/c/src -I $(OMNI_HOME)/c/src -o build/conform \
	  $(STATION_SRC) $(STRUCT_OBJ) $(OMNI_OBJ) test/conform.c $(LDLIBS)

test: build
	./build/unit
	./build/conform

# The shape artifact is DATA (design 4.3) and spec/config-shape.json is
# the copy every port reads; this library is vendored into a compiled
# SDK that cannot see spec/ at run time, so src/config_shape.h is a
# MIRROR of it. Re-run after editing the spec - test/unit.c's shape
# check fails on drift.
sync-shape:
	python3 tools/sync-shape.py

clean:
	rm -rf build

inspect:
	@$(CC) --version | head -1
	@echo "omni:   $(OMNI_HOME)"
	@echo "struct: $(STRUCT_DIR)"
