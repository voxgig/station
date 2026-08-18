.PHONY: build test clean inspect

export DOTNET_CLI_TELEMETRY_OPTOUT = 1
export DOTNET_NOLOGO = 1

# voxgig/sekreto (the one library dependency, station design 10) and
# voxgig/omni (the conformance runner) are sibling checkouts, not
# published artifacts, and they may sit anywhere. Find them and point the
# project references at them.
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

# The library references nothing but the BCL and sekreto. Only the
# conformance suite needs omni.
build:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	dotnet build src -c Release -v q --nologo -p:SekretoPath=$(SEKRETO)/csharp/src/Sekreto.csproj

test:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	dotnet build test -v q --nologo -p:SekretoPath=$(SEKRETO)/csharp/src/Sekreto.csproj -p:OmniPath=$(OMNI)/csharp/src/Omni.csproj
	./test/bin/Debug/net8.0/stationtest

clean:
	rm -rf src/bin src/obj test/bin test/obj

inspect:
	@dotnet --version
	@echo "sekreto: $(SEKRETO)"
	@echo "omni: $(OMNI)"
