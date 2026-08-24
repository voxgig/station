.PHONY: build test clean inspect sync-shape

# voxgig/sekreto (secrets, station design 10) and voxgig/struct (the
# config-shape validator, design 4 and 9) are the two RUNTIME dependencies,
# and voxgig/omni is the conformance runner. None is a published artifact
# yet, and they may sit anywhere: find them the way this port already found
# omni, and build them if they have not been built.
SEKRETO := $(shell \
  for d in "$$SEKRETO_HOME" ../../sekreto ../../../sekreto /workspace/sekreto /home/user/sekreto; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/sekreto.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

STRUCT := $(shell \
  for d in "$$STRUCT_HOME" ../../struct ../../../struct /workspace/struct /home/user/struct; do \
    if [ -n "$$d" ] && [ -f "$$d/java/src/Struct.java" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# struct's own build is Maven; this port needs the one class file and
# nothing else, so it compiles the single source directly - no network, no
# local repository, and the same javac the rest of this port uses.
build:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(STRUCT)" || { echo "station: voxgig/struct not found - set STRUCT_HOME" >&2; exit 1; }
	$(MAKE) -C $(SEKRETO)/java build
	mkdir -p build/struct
	javac -d build/struct $(STRUCT)/java/src/Struct.java
	mkdir -p build/classes
	javac -cp build/struct:$(SEKRETO)/java/build/classes -d build/classes src/com/voxgig/station/*.java
	cp src/com/voxgig/station/config-shape.json build/classes/com/voxgig/station/

test: build
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	$(MAKE) -C $(OMNI)/java build
	mkdir -p build/test
	javac -cp build/classes:build/struct:$(SEKRETO)/java/build/classes:$(OMNI)/java/build -d build/test test/StationTest.java
	cp -r test/resources/. build/test/
	java -cp build/classes:build/test:build/struct:$(SEKRETO)/java/build/classes:$(OMNI)/java/build StationTest

# The shape artifact is DATA (design 4.3), and spec/config-shape.json is the
# copy every port reads. A jar ships compiled and cannot see spec/ at run
# time, while validateConfig runs at open() - so this port carries a MIRROR
# on the classpath. Re-run this after editing the spec; StationTest's
# `shape: the mirror has not drifted` case fails on drift.
sync-shape:
	cp ../spec/config-shape.json src/com/voxgig/station/config-shape.json

clean:
	rm -rf build

inspect:
	@javac -version 2>&1 | tail -1
	@echo "sekreto: $(SEKRETO)"
	@echo "struct:  $(STRUCT)"
	@echo "omni:    $(OMNI)"
