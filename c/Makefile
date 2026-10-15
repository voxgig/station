# station - C port. Standalone unit tests, the shared conformance corpus
# (spec/station.json) through the sibling voxgig/omni C runner (or
# OMNI_HOME), and the secret-store suite over a real mini vault.

CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2
LDLIBS ?= -lm

# `make asan` rebuilds everything, dependencies included, into its own
# tree with SANITIZE appended to every compile and link.
BUILD ?= build
SANITIZE ?=

STATION_SRC = src/voxgig_station.c src/voxgig_station_shape.c \
  src/voxgig_station_feature.c src/voxgig_station_factory.c \
  src/voxgig_station_secrets.c
STATION_OBJ = $(addprefix $(BUILD)/station/,$(notdir $(STATION_SRC:.c=.o)))
STATION_HDR = src/voxgig_station.h src/voxgig_station_int.h src/config_shape.h

OMNI_HOME ?= $(abspath ../../omni)
OMNI_SRC = $(OMNI_HOME)/c/src/json.c $(OMNI_HOME)/c/src/util.c $(OMNI_HOME)/c/src/runner.c
OMNI_OBJ = $(addprefix $(BUILD)/omni/,$(notdir $(OMNI_SRC:.c=.o)))

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
STRUCT_OBJ = $(addprefix $(BUILD)/struct/,$(notdir $(STRUCT_SRC:.c=.o)))

# struct's own flags, not this port's: it is a vendored dependency
# compiled as its own project ships it, and -Werror over somebody
# else's warnings is a build that breaks on their next release.
STRUCT_CFLAGS = -std=c11 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE -O2

# voxgig/sekreto resolves secrets (design station.md 5, 10), VENDORED at
# vendor/sekreto from the commit tools/vendor.py pins. The core is the
# chain and the four built-in kinds; minivault is a plugin, and with the
# encoder it links, the only code here that needs libcrypto. Built with
# sekreto's own flags, for the reason struct is, plus the two warnings
# that mean a miscompiled call made fatal.
SEKRETO_DIR = vendor/sekreto
SEKRETO_HDR = $(wildcard $(SEKRETO_DIR)/src/*.h $(SEKRETO_DIR)/plugins/*.h)
SEKRETO_OBJ = $(addprefix $(BUILD)/sekreto/,$(notdir $(patsubst %.c,%.o,$(wildcard $(SEKRETO_DIR)/src/*.c))))
MINIVAULT_OBJ = $(BUILD)/minivault/minivault.o $(BUILD)/minivault/encode.o
SEKRETO_CFLAGS = -std=c99 -Wall -Wextra -O2 \
  -Werror=implicit-function-declaration -Werror=int-conversion
# minivault.c calls realpath under _POSIX_C_SOURCE alone, where glibc does
# not declare it unless fortification happens to: an implicit int
# declaration would truncate the pointer it returns.
MINIVAULT_CFLAGS = $(SEKRETO_CFLAGS) -D_DEFAULT_SOURCE
MINIVAULT_LDLIBS = -lcrypto -lpthread

# voxgig/plugin is sekreto's own dependency - the host its provider kinds
# are definitions on - found the way struct is. Its own flags too, -O1
# included: at -O2 gcc's -Wclobbered fires on its setjmp frames.
PLUGIN_DIR := $(shell \
  for d in "$$PLUGIN_HOME" ../../plugin ../../../plugin /workspace/plugin /home/user/plugin; do \
    if [ -n "$$d" ] && [ -f "$$d/c/src/host.h" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)
PLUGIN_SRC = $(wildcard $(PLUGIN_DIR)/c/src/*.c)
PLUGIN_OBJ = $(addprefix $(BUILD)/plugin/,$(notdir $(PLUGIN_SRC:.c=.o)))
PLUGIN_CFLAGS = -std=c11 -Wall -Wextra -O1 -g

SEKRETO_INC = -I $(SEKRETO_DIR)/src -I $(SEKRETO_DIR)/plugins -I $(PLUGIN_DIR)/c/src

# What a consumer links, in link order. None of the four reaches crypto;
# a consumer whose chain names minivault puts MINIVAULT_LIB in front and
# adds MINIVAULT_LDLIBS.
CORE_LIBS = $(BUILD)/libvxstn.a $(BUILD)/libsekreto.a $(BUILD)/libvoxgigplugin.a \
  $(BUILD)/libvoxgigstruct.a
MINIVAULT_LIB = $(BUILD)/libsekretominivault.a

TESTS = $(BUILD)/unit $(BUILD)/unit-envonly $(BUILD)/conform $(BUILD)/secrets

.PHONY: build test suites check-core asan valgrind clean inspect sync-shape \
  struct-check plugin-check

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

plugin-check:
	@if [ -z "$(PLUGIN_DIR)" ]; then \
	  echo "station: voxgig/plugin checkout not found - set PLUGIN_HOME."; \
	  echo "  sekreto's C core is built on its host (vendor/sekreto/src/sekreto.h)."; \
	  echo "  git clone https://github.com/voxgig/plugin ../../plugin"; \
	  exit 1; \
	fi

# Each dependency is compiled on ITS OWN include path, never with
# `-I src` or with another dependency's. struct ships `src/regex.h` and
# omni's util.c does `#include <regex.h>` wanting POSIX's: one shared
# command line put struct's on the angle-bracket search path and
# regex_t stopped existing. (The same shadowing struct's own Makefile
# records, in the other direction.)
$(BUILD)/struct/%.o: $(STRUCT_DIR)/c/src/%.c
	@mkdir -p $(@D)
	$(CC) -c $< $(STRUCT_CFLAGS) $(SANITIZE) -I $(STRUCT_DIR)/c/src -o $@

$(BUILD)/omni/%.o: $(OMNI_HOME)/c/src/%.c
	@mkdir -p $(@D)
	$(CC) -c $< $(CFLAGS) $(SANITIZE) -I $(OMNI_HOME)/c/src -o $@

$(BUILD)/plugin/%.o: $(PLUGIN_DIR)/c/src/%.c
	@mkdir -p $(@D)
	$(CC) -c $< $(PLUGIN_CFLAGS) $(SANITIZE) -I $(PLUGIN_DIR)/c/src -o $@

$(BUILD)/sekreto/%.o: $(SEKRETO_DIR)/src/%.c $(SEKRETO_HDR)
	@mkdir -p $(@D)
	$(CC) -c $< $(SEKRETO_CFLAGS) $(SANITIZE) $(SEKRETO_INC) -o $@

$(BUILD)/minivault/%.o: $(SEKRETO_DIR)/plugins/%.c $(SEKRETO_HDR)
	@mkdir -p $(@D)
	$(CC) -c $< $(MINIVAULT_CFLAGS) $(SANITIZE) $(SEKRETO_INC) -o $@

$(BUILD)/station/voxgig_station_secrets.o: src/voxgig_station_secrets.c $(STATION_HDR) $(SEKRETO_HDR)
	@mkdir -p $(@D)
	$(CC) -c $< $(CFLAGS) $(SANITIZE) $(SEKRETO_INC) -o $@

$(BUILD)/station/%.o: src/%.c $(STATION_HDR)
	@mkdir -p $(@D)
	$(CC) -c $< $(CFLAGS) $(SANITIZE) -I $(STRUCT_DIR)/c/src -o $@

# The sdkgen-station payload's broker: the environment, and no sekreto.
$(BUILD)/envonly/voxgig_station_secrets.o: src/voxgig_station_secrets.c $(STATION_HDR)
	@mkdir -p $(@D)
	$(CC) -c $< $(CFLAGS) $(SANITIZE) -DVXSTN_ENV_ONLY -o $@

# `ar r` keeps a member whose source has gone, so every archive is
# written cold.
$(BUILD)/libvxstn.a: $(STATION_OBJ)
	@rm -f $@
	ar rcs $@ $^

$(BUILD)/libsekreto.a: $(SEKRETO_OBJ)
	@rm -f $@
	ar rcs $@ $^

$(BUILD)/libvoxgigplugin.a: $(PLUGIN_OBJ)
	@rm -f $@
	ar rcs $@ $^

$(BUILD)/libvoxgigstruct.a: $(STRUCT_OBJ)
	@rm -f $@
	ar rcs $@ $^

$(MINIVAULT_LIB): $(MINIVAULT_OBJ)
	@rm -f $@
	ar rcs $@ $^

$(BUILD)/unit: test/unit.c $(STATION_HDR) $(CORE_LIBS)
	$(CC) $(CFLAGS) $(SANITIZE) -o $@ $< $(CORE_LIBS) $(LDLIBS)

$(BUILD)/unit-envonly: test/unit.c $(STATION_HDR) $(filter-out %/voxgig_station_secrets.o,$(STATION_OBJ)) \
    $(BUILD)/envonly/voxgig_station_secrets.o $(BUILD)/libvoxgigstruct.a
	$(CC) $(CFLAGS) $(SANITIZE) -DVXSTN_ENV_ONLY -o $@ $< \
	  $(filter-out %/voxgig_station_secrets.o,$(STATION_OBJ)) \
	  $(BUILD)/envonly/voxgig_station_secrets.o $(BUILD)/libvoxgigstruct.a $(LDLIBS)

$(BUILD)/conform: test/conform.c $(STATION_HDR) $(OMNI_OBJ) $(CORE_LIBS)
	$(CC) $(CFLAGS) $(SANITIZE) -I $(OMNI_HOME)/c/src -o $@ $< $(OMNI_OBJ) $(CORE_LIBS) $(LDLIBS)

$(BUILD)/secrets: test/secrets.c $(STATION_HDR) $(MINIVAULT_LIB) $(CORE_LIBS)
	$(CC) $(CFLAGS) $(SANITIZE) $(SEKRETO_INC) -o $@ $< $(MINIVAULT_LIB) $(CORE_LIBS) \
	  $(MINIVAULT_LDLIBS) $(LDLIBS)

build: struct-check plugin-check
	@$(MAKE) --no-print-directory $(TESTS)

# Read off the built artifacts: test/checkcore.sh says what it proves.
check-core: build
	@./test/checkcore.sh $(BUILD) $(SEKRETO_DIR)

suites: build
	$(RUN) ./$(BUILD)/unit
	$(RUN) ./$(BUILD)/unit-envonly
	$(RUN) ./$(BUILD)/conform
	$(RUN_SECRETS) ./$(BUILD)/secrets

test: check-core suites

# Leak detection is on for the secret-store suite, which frees what it
# opens, apart from the tree struct's validator builds (test/leaks.supp);
# the unit and conformance suites leak in their own fixtures.
UBSAN_RUN = UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
asan:
	@$(MAKE) --no-print-directory BUILD=build/asan \
	  SANITIZE="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g -O1" \
	  RUN="$(UBSAN_RUN) ASAN_OPTIONS=detect_leaks=0" \
	  RUN_SECRETS="$(UBSAN_RUN) ASAN_OPTIONS=detect_leaks=1 LSAN_OPTIONS=suppressions=test/leaks.supp" \
	  suites

VALGRIND = valgrind --quiet --error-exitcode=99 --track-origins=yes --num-callers=64
valgrind:
	@command -v valgrind >/dev/null || { echo 'valgrind is not installed; nothing was checked' >&2; exit 1; }
	@$(MAKE) --no-print-directory RUN="$(VALGRIND) --leak-check=no" \
	  RUN_SECRETS="$(VALGRIND) --leak-check=full --show-leak-kinds=definite,indirect \
	    --errors-for-leak-kinds=definite,indirect --suppressions=test/valgrind.supp" \
	  suites

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
	@echo "omni:    $(OMNI_HOME)"
	@echo "struct:  $(STRUCT_DIR)"
	@echo "plugin:  $(PLUGIN_DIR)"
	@echo "sekreto: $$(sed -n 's/^\/\/ Source: .* @ //p' $(SEKRETO_DIR)/src/sekreto.h)"
