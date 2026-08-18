# station - per-language build/test drivers.
# Layout follows the sibling multi-port libraries (sekreto, omni):
# per-language directories, spec/ at the root.

test: test-typescript

test-typescript:
	cd typescript && npm test

build-typescript:
	cd typescript && npm run build

.PHONY: test test-typescript build-typescript
