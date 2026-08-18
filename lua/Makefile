# station - Lua port. Zero-dependency tests (the omni lua harness
# pattern); the conformance suite needs a sibling voxgig/omni checkout
# (or OMNI_HOME).

LUA ?= lua5.4

.PHONY: build test clean inspect

build:

test:
	$(LUA) test/station.lua
	$(LUA) test/conform.lua

clean:

inspect:
	@$(LUA) -v
