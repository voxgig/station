# station - C port. Standalone unit tests plus the shared conformance
# corpus (spec/station.json) through the sibling voxgig/omni C runner
# (or OMNI_HOME).

CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2
LDLIBS ?= -lm

OMNI_HOME ?= $(abspath ../../omni)
OMNI_SRC = $(OMNI_HOME)/c/src/json.c $(OMNI_HOME)/c/src/util.c $(OMNI_HOME)/c/src/runner.c

.PHONY: build test clean inspect

build:
	mkdir -p build
	$(CC) $(CFLAGS) -o build/unit src/voxgig_station.c test/unit.c $(LDLIBS)
	$(CC) $(CFLAGS) -I $(OMNI_HOME)/c/src -o build/conform \
	  src/voxgig_station.c $(OMNI_SRC) test/conform.c $(LDLIBS)

test: build
	./build/unit
	./build/conform

clean:
	rm -rf build

inspect:
	@$(CC) --version | head -1
