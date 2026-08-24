#!/usr/bin/env python3
"""Regenerate c/src/config_shape.h from spec/config-shape.json.

The shape artifact is DATA (design station.md 4.3), and
`spec/config-shape.json` is the copy every port reads. The C library is
VENDORED into a generated SDK (sdkgen-station .sdk/tm/c/feature/station/)
and `validateConfig` runs at open() rather than only under test, so it
cannot read `spec/` at run time: the header below is a MIRROR of the
spec file, embedded verbatim.

Re-run this after editing the spec (`make -C c sync-shape`);
test/unit.c's `shape mirror` check compares the embedded bytes against
`spec/config-shape.json` and fails on drift.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.normpath(os.path.join(HERE, '..', '..', 'spec', 'config-shape.json'))
OUT = os.path.normpath(os.path.join(HERE, '..', 'src', 'config_shape.h'))

HEAD = '''/* GENERATED FILE - DO NOT EDIT. Run `make sync-shape` (c/tools/sync-shape.py).
 *
 * The config grammar as data (design station.md 4.3), mirrored verbatim
 * from voxgig/station `spec/config-shape.json` - the one artifact every
 * port reads.
 *
 * A MIRROR rather than a run-time file read, because this library is
 * vendored into a generated C SDK and `vxstn_validate_config` runs at
 * open(), not only under test: there is no `spec/` beside the compiled
 * SDK to read. test/unit.c compares these bytes against the spec file
 * and fails on drift, which is what keeps a mirror honest.
 *
 * Line-per-line string literals, so a diff of this file reads like a
 * diff of the spec.
 */

#ifndef VOXGIG_STATION_CONFIG_SHAPE_H
#define VOXGIG_STATION_CONFIG_SHAPE_H

static const char VXSTN_CONFIG_SHAPE_JSON[] =
'''

TAIL = '''
#endif /* VOXGIG_STATION_CONFIG_SHAPE_H */
'''


def cstr(line):
    out = ['"']
    for ch in line:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\t':
            out.append('\\t')
        elif ord(ch) < 0x20:
            out.append('\\%03o' % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def main():
    with open(SPEC, 'r', encoding='utf-8') as f:
        text = f.read()

    # A parse here is a guard, not a transform: the bytes are mirrored
    # verbatim so the drift check can be a byte compare.
    json.loads(text)

    lines = text.splitlines(keepends=True)
    body = '\n'.join('  ' + cstr(line) for line in lines)

    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(HEAD + body + ';\n' + TAIL)

    print('sync-shape: %d bytes -> %s' % (len(text), OUT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
