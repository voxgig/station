#!/usr/bin/env python3
"""Regenerate the embedded config shape inside cpp/src/voxgig_station.hpp.

The shape artifact is DATA (design station.md 4.3), and
`spec/config-shape.json` is the copy every port reads. The C++ library is
VENDORED into a generated C++ SDK (sdkgen-station
`.sdk/tm/cpp/feature/station/`) and `validate_config` runs at open()
rather than only under test, so it cannot read `spec/` at run time: the
region below is a MIRROR of the spec file, embedded verbatim.

It goes INSIDE the one header rather than beside it, because "one header,
one file" is this port's vendoring contract (README.md, VENDORED.md) - a
second file would have to be copied into every generated SDK too.

Re-run after editing the spec (`make -C cpp sync-shape`); test/unit.cpp's
`config-shape-mirror-matches-spec` check compares the embedded bytes
against `spec/config-shape.json` and fails on drift.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.normpath(os.path.join(HERE, '..', '..', 'spec', 'config-shape.json'))
OUT = os.path.normpath(os.path.join(HERE, '..', 'src', 'voxgig_station.hpp'))

BEGIN = '// --- BEGIN GENERATED: config-shape (cpp/tools/sync-shape.py) ---'
END = '// --- END GENERATED: config-shape ---'

BODY = '''// The mirrored bytes of `spec/config-shape.json`, verbatim, so a diff of
// this region reads like a diff of the spec.
inline const char* config_shape_json() {
  static const char* const SHAPE = R"SHAPE({shape})SHAPE";
  return SHAPE;
}'''


def main() -> None:
    with open(SPEC, 'r', encoding='utf-8') as handle:
        shape = handle.read()

    if ')SHAPE"' in shape:
        sys.exit('sync-shape: the spec contains the raw-string delimiter')

    with open(OUT, 'r', encoding='utf-8') as handle:
        text = handle.read()

    start = text.find(BEGIN)
    stop = text.find(END)
    if -1 == start or -1 == stop or stop < start:
        sys.exit('sync-shape: generated region not found in ' + OUT)

    block = BEGIN + '\n' + BODY.replace('{shape}', shape) + '\n' + END
    text = text[:start] + block + text[stop + len(END):]

    with open(OUT, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print('sync-shape: wrote the config-shape region of ' +
          os.path.relpath(OUT, os.path.join(HERE, '..', '..')))


if __name__ == '__main__':
    main()
