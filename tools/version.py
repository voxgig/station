#!/usr/bin/env python3
"""Every station port declares one version: the one in VERSION.

    python3 tools/version.py --check        # exit 1 naming each declaration that differs
    python3 tools/version.py --set 0.3.0    # write VERSION and every declaration
    python3 tools/version.py --print        # the shared version

Go declares none: its version is its tag. A declaration is a file and a
pattern whose second group is the version. `count` is how many matches the
file must hold, so an edit that moves a declaration out of the pattern's
reach fails the check instead of passing.
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FOUND = r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?'

# SemVer's grammar without build metadata, which a go module version
# cannot carry: no leading zeros, no empty prerelease identifier.
NUM = r'(?:0|[1-9]\d*)'
PRE = r'(?:' + NUM + r'|\d*[A-Za-z-][0-9A-Za-z-]*)'
SEMVER_RE = re.compile(
    r'^' + NUM + r'\.' + NUM + r'\.' + NUM + r'(?:-' + PRE + r'(?:\.' + PRE + r')*)?$')

PAYLOAD = 'sdkgen-station/.sdk/tm/'


def decl(path, pattern, count=1):
    return {
        'path': path,
        're': re.compile(pattern.replace('{V}', '(' + FOUND + ')'), re.M),
        'count': count,
    }


DECLARATIONS = [
    decl('typescript/package.json', r'^(  "version": "){V}(")'),
    decl('typescript/package-lock.json',
         r'("name": "@voxgig/station",\n\s+"version": "){V}(")', 2),
    decl('javascript/package.json', r'^(  "version": "){V}(")'),
    decl('javascript/package-lock.json',
         r'("name": "@voxgig/station-js",\n\s+"version": "){V}(")', 2),
    decl('python/pyproject.toml', r'^(version = "){V}(")'),
    decl('rust/Cargo.toml', r'^(version = "){V}(")'),
    decl('rust/Cargo.lock', r'(name = "voxgig_station"\nversion = "){V}(")'),
    decl('csharp/src/Station.csproj', r'(<Version>){V}(</Version>)'),
    decl('dart/pubspec.yaml', r'^(version: ){V}()$'),
    decl('elixir/mix.exs', r'^(\s+version: "){V}(",)$'),
    decl('lua/src/voxgig_station.lua', r"^(M\.VERSION = '){V}(')"),
    decl(PAYLOAD + 'lua/feature/station/voxgig_station.lua',
         r"^(M\.VERSION = '){V}(')"),
    decl('perl/lib/Voxgig/Station.pm', r"^(our \$VERSION = '){V}(';)"),
    decl(PAYLOAD + 'perl/feature/station/lib/Voxgig/Station.pm',
         r"^(our \$VERSION = '){V}(';)"),
    decl('c/src/voxgig_station.h', r'^(#define VXSTN_VERSION "){V}(")'),
    decl(PAYLOAD + 'c/feature/station/voxgig_station.h',
         r'^(#define VXSTN_VERSION "){V}(")'),
    decl('cpp/src/voxgig_station.hpp',
         r'^(inline const char\* VERSION = "){V}(";)'),
    decl(PAYLOAD + 'cpp/feature/station/voxgig_station.hpp',
         r'^(inline const char\* VERSION = "){V}(";)'),
    decl('ruby/lib/voxgig_station/station.rb', r"^(  VERSION = '){V}(')"),
    decl('php/src/Station.php', r"^(const VERSION = '){V}(';)"),
    decl('java/src/com/voxgig/station/Station.java',
         r'^(  public static final String VERSION = "){V}(";)'),
    decl('swift/Sources/VoxgigStation/Station.swift',
         r'^(  public static let version = "){V}(")'),
    decl('proxy/internal/daemon/config.go', r'^(const Version = "){V}(")'),
    # The library each generated SDK depends on, one entry per target.
    decl('sdkgen-station/.sdk/model/feature/station.aontu',
         r"^(\s+'[^']*[Ss]tation[^']*': \{ active: true, version: '(?:>=|v)?){V}(')",
         12),
]


def read(root, path):
    with open(os.path.join(root, path), encoding='utf-8') as f:
        return f.read()


def write(root, path, text):
    with open(os.path.join(root, path), 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def shared(root):
    text = read(root, 'VERSION').strip()
    if not SEMVER_RE.match(text):
        raise SystemExit('VERSION holds %r, which is not a SemVer X.Y.Z[-pre]' % text)
    return text


def line_of(text, offset):
    return text.count('\n', 0, offset) + 1


def check(root, out=sys.stdout):
    version = shared(root)
    problems = []
    for d in DECLARATIONS:
        try:
            text = read(root, d['path'])
        except FileNotFoundError:
            problems.append('%s: missing' % d['path'])
            continue
        found = list(d['re'].finditer(text))
        if len(found) != d['count']:
            problems.append('%s: expected %d version declaration(s), found %d'
                            % (d['path'], d['count'], len(found)))
        for m in found:
            if m.group(2) != version:
                problems.append('%s:%d: declares %s, VERSION says %s'
                                % (d['path'], line_of(text, m.start(2)),
                                   m.group(2), version))
    for p in problems:
        print(p, file=out)
    if not problems:
        print('every declaration says %s (%d files)' % (version, len(DECLARATIONS)),
              file=out)
    return not problems


def set_version(root, version):
    if not SEMVER_RE.match(version):
        raise SystemExit('%r is not a SemVer X.Y.Z[-pre]' % version)
    rewritten = {}
    for d in DECLARATIONS:
        text = rewritten.get(d['path'], read(root, d['path']))
        new, n = d['re'].subn(lambda m: m.group(1) + version + m.group(3), text)
        if n != d['count']:
            raise SystemExit('%s: expected %d version declaration(s), found %d; '
                             'nothing was written' % (d['path'], d['count'], n))
        rewritten[d['path']] = new
    for path, text in rewritten.items():
        if text != read(root, path):
            write(root, path, text)
    write(root, 'VERSION', version + '\n')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--set', metavar='X.Y.Z')
    mode.add_argument('--print', action='store_true')
    ap.add_argument('--root', default=ROOT, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    if args.print:
        print(shared(args.root))
        return 0
    if args.set:
        set_version(args.root, args.set)
    return 0 if check(args.root) else 1


if __name__ == '__main__':
    sys.exit(main())
