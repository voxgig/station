# Locate the sibling voxgig/struct checkout whose python port backs
# validate_config (design station.md 4).
#
# struct is not published yet, so this port finds it on disk - by
# $STRUCT_HOME, or by looking where a checkout usually sits. (The same
# convention omnihome.py uses for voxgig/omni, and sekreto follows.)
# Unlike omni this is a RUNTIME dependency: validate_config runs at
# open(), not just under test.
#
# A port of javascript/src/structhome.js; typescript/src/shape.ts is
# canonical for what it is used for.

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

_MARKER = os.path.join('python', 'voxgig_struct', 'voxgig_struct.py')


def structhome(marker=_MARKER):
    candidates = [
        os.environ.get('STRUCT_HOME'),
        os.path.join(_HERE, '..', '..', '..', 'struct'),
        os.path.join(_HERE, '..', '..', '..', '..', 'struct'),
        '/workspace/struct',
        '/home/user/struct',
    ]

    for candidate in candidates:
        if candidate and os.path.exists(os.path.join(candidate, marker)):
            return os.path.abspath(candidate)

    raise FileNotFoundError('station: voxgig/struct not found - set STRUCT_HOME')


def structmod():
    """The struct python port itself: the installed package when there is
    one, else the sibling checkout - the same order tests use for
    sekreto."""
    try:
        import voxgig_struct
    except ImportError:
        path = os.path.join(structhome(), 'python')
        if path not in sys.path:
            sys.path.insert(0, path)
        import voxgig_struct
    return voxgig_struct
