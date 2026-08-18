.PHONY: build test clean inspect

# Dependency-free: the library uses only dart:io/dart:convert, and the
# test harness is a plain `dart run` runner (no package:test). The
# conformance half imports the sibling voxgig/omni checkout's Dart
# runner by relative path (../../omni), the layout every port assumes.

build:
	dart analyze

# The env-hit broker/injection cases read these; run without them the
# cases skip with a notice (Dart cannot set process env vars in-process).
test:
	STATIONTEST_ONE_APIKEY=v-one \
	STATIONTEST_FIRST_APIKEY=hit \
	GNARLY_PETS_APIKEY=gnarly-key-101 \
	dart run test/run.dart

clean:
	rm -rf build

inspect:
	@dart --version
