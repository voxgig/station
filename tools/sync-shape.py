#!/usr/bin/env python3
"""Mirror spec/config-shape.json into the shipped copies of the npm ports.

Neither published package carries `spec/`, so a runtime read of it works in
the repo and breaks in a consumer - and validateConfig runs at open(), not
just under test. typescript/test/shape.test.ts and
javascript/test/shape.test.js fail on drift.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'spec', 'config-shape.json')
OUT = os.path.join(ROOT, 'typescript', 'src', 'config-shape.ts')
JS_OUT = os.path.join(ROOT, 'javascript', 'src', 'config-shape.js')

HEADER = '''
export const CONFIG_SHAPE: any = '''

JS_HEADER = '''
module.exports.CONFIG_SHAPE = '''


def main() -> None:
    with open(SRC) as f:
        shape = json.load(f)
    for out, header in ((OUT, HEADER), (JS_OUT, JS_HEADER)):
        with open(out, 'w') as f:
            f.write(header + json.dumps(shape, indent=2) + '\n')
        print('sync-shape: wrote ' + os.path.relpath(out, ROOT))


if __name__ == '__main__':
    main()
