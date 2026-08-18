# Locate the sibling voxgig/omni checkout that drives the shared spec.
#
# station's conformance tests are omni tests: the same spec/station.json
# runs in every port. omni is not published yet, so the tests find it on
# disk - by $OMNI_HOME, or by looking where a checkout usually sits.
# (The same convention sekreto uses.)
#
# A port of typescript/src/omnihome.ts.

import os

_HERE = os.path.dirname(os.path.abspath(__file__))


def omnihome(marker=os.path.join('spec', 'fib.json')):
    candidates = [
        os.environ.get('OMNI_HOME'),
        os.path.join(_HERE, '..', '..', '..', 'omni'),
        os.path.join(_HERE, '..', '..', '..', '..', 'omni'),
        '/workspace/omni',
        '/home/user/omni',
    ]

    for candidate in candidates:
        if candidate and os.path.exists(os.path.join(candidate, marker)):
            return os.path.abspath(candidate)

    raise FileNotFoundError('station: voxgig/omni not found - set OMNI_HOME')


def specfile():
    """The station spec, wherever this port is running from."""
    return os.path.abspath(
        os.path.join(_HERE, '..', '..', 'spec', 'station.json'))
