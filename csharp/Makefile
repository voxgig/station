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

# voxgig/plugin, found the same way and for the same reason: sekreto's
# provider kinds moved onto it (sekreto 43eb579), so sekreto's own csproj
# now takes a PluginPath and errors without one. Nothing here references
# plugin directly - the path is handed to msbuild, which propagates it to
# the referenced sekreto projects.
PLUGIN := $(shell \
  for d in "$$PLUGIN_HOME" ../../plugin ../../../plugin /workspace/plugin /home/user/plugin; do \
    if [ -n "$$d" ] && [ -f "$$d/csharp/src/VoxgigPlugin.csproj" ]; then \
      (cd "$$d" && pwd); break; \
    fi; \
  done)

# The three paths every dotnet invocation here carries: sekreto's core,
# its plugins assembly (SekretoPlugins.All(), the chain a station.json
# may name), and the plugin library both of those sit on.
SEKPATHS = -p:SekretoPath=$(SEKRETO)/csharp/src/Sekreto.csproj \
  -p:SekretoPluginsPath=$(SEKRETO)/csharp/plugins/SekretoPlugins.csproj \
  -p:PluginPath=$(PLUGIN)/csharp/src/VoxgigPlugin.csproj

# The library references nothing but the BCL and sekreto. Only the
# conformance suite needs omni.
build:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(PLUGIN)" || { echo "station: voxgig/plugin not found - set PLUGIN_HOME (sekreto needs it)" >&2; exit 1; }
	dotnet build src -c Release -v q --nologo $(SEKPATHS)

test:
	@test -n "$(SEKRETO)" || { echo "station: voxgig/sekreto not found - set SEKRETO_HOME" >&2; exit 1; }
	@test -n "$(OMNI)" || { echo "station: voxgig/omni not found - set OMNI_HOME" >&2; exit 1; }
	@test -n "$(PLUGIN)" || { echo "station: voxgig/plugin not found - set PLUGIN_HOME (sekreto needs it)" >&2; exit 1; }
	dotnet build test -v q --nologo $(SEKPATHS) -p:OmniPath=$(OMNI)/csharp/src/Omni.csproj
	./test/bin/Debug/net8.0/stationtest

clean:
	rm -rf src/bin src/obj test/bin test/obj

inspect:
	@dotnet --version
	@echo "sekreto: $(SEKRETO)"
	@echo "omni: $(OMNI)"
	@echo "plugin: $(PLUGIN)"
