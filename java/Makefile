.PHONY: build test clean inspect

# voxgig/sekreto (the one library dependency, station design 10) and
# voxgig/omni (the conformance runner) are sibling checkouts, not
# published artifacts, and they may sit anywhere. Find them, and build
# them if they have not been built yet.
SEKRETO := $(shell \
  for d in "$$SEKRETO_HOME" ../../sekreto ../../../sekreto /workspace/sekreto /home/user/sekreto; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/sekreto.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

OMNI := $(shell \
  for d in "$$OMNI_HOME" ../../omni ../../../omni /workspace/omni /home/user/omni; do \
    if [ -n "$$d" ] && [ -f "$$d/spec/fib.json" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

build:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	$(MAKE) -C $(SEKRETO)/java build
	mkdir -p build/classes
	javac -cp $(SEKRETO)/java/build/classes -d build/classes src/com/voxgig/station/*.java

test: build
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	$(MAKE) -C $(OMNI)/java build
	mkdir -p build/test
	javac -cp build/classes:$(SEKRETO)/java/build/classes:$(OMNI)/java/build -d build/test test/StationTest.java
	java -cp build/classes:build/test:$(SEKRETO)/java/build/classes:$(OMNI)/java/build StationTest

clean:
	rm -rf build

inspect:
	@javac -version 2>&1 | tail -1
	@echo "sekreto: $(SEKRETO)"
	@echo "omni: $(OMNI)"
