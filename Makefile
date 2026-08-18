# station - per-language build/test drivers.
# Layout follows the sibling multi-port libraries (sekreto, omni):
# per-language directories, spec/ at the root.

test: test-typescript test-javascript

test-typescript:
	cd typescript && npm test

test-javascript:
	cd javascript && npm test

build-typescript:
	cd typescript && npm run build

.PHONY: test test-typescript test-javascript build-typescript
