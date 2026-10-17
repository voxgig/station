#!/usr/bin/env python3
"""Mutation test for tools/version.py.

A guard that has never failed is not a guard. Against a scratch copy of the
tree this moves each declaration to another version, and deletes each one,
and requires the check to fail naming that file; then it requires `--set` to
leave a tree the check accepts.

Exit status: 0 if every mutation produced the expected verdict, 1 otherwise.
"""

import importlib.util
import io
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_spec = importlib.util.spec_from_file_location(
    'version', os.path.join(ROOT, 'tools', 'version.py'))
V = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(V)


def copy_tree(dest):
    for rel in ['VERSION'] + [d['path'] for d in V.DECLARATIONS]:
        os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
        shutil.copyfile(os.path.join(ROOT, rel), os.path.join(dest, rel))


def verdict(root):
    out = io.StringIO()
    ok = V.check(root, out)
    return ok, out.getvalue()


def mutate(root, d, replace):
    text = V.read(root, d['path'])
    m = d['re'].search(text)
    V.write(root, d['path'], text[:m.start()] + replace(m) + text[m.end():])
    return text


def other(version):
    major, rest = version.split('.', 1)
    return str(int(major) + 1) + '.' + rest


def main():
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        copy_tree(tmp)
        ok, out = verdict(tmp)
        results.append(('PASS' if ok else 'FAIL', 'baseline', out.strip()))
        version = V.shared(tmp)

        for d in V.DECLARATIONS:
            for tag, replace in (
                ('moved', lambda m: m.group(1) + other(version) + m.group(3)),
                ('deleted', lambda m: ''),
            ):
                original = mutate(tmp, d, replace)
                try:
                    ok, out = verdict(tmp)
                finally:
                    V.write(tmp, d['path'], original)
                caught = not ok and d['path'] in out
                results.append(('PASS' if caught else 'FAIL',
                                '%s:%s' % (d['path'], tag),
                                'caught' if caught else 'NOT caught'))

        V.set_version(tmp, '1.2.3-rc.1')
        ok, out = verdict(tmp)
        good = ok and '1.2.3-rc.1' == V.shared(tmp)
        results.append(('PASS' if good else 'FAIL', 'set', out.strip()))

        V.write(tmp, 'VERSION', 'one\n')
        try:
            V.shared(tmp)
            results.append(('FAIL', 'VERSION:not-semver', 'accepted'))
        except SystemExit:
            results.append(('PASS', 'VERSION:not-semver', 'refused'))

    for status, tag, note in results:
        print('%s  %-72s %s' % (status, tag, note))
    bad = [r for r in results if 'PASS' != r[0]]
    print('\n%d/%d mutations produced the expected verdict'
          % (len(results) - len(bad), len(results)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
