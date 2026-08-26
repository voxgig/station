#!/usr/bin/env python3
"""Omni register 4.13: no port's LIBRARY may declare voxgig/omni.

omni is the conformance runner. It is a TEST dependency of every port here
and a published dependency of none, so nothing a consumer of station
resolves may name it.

WHY THIS IS NOT A BUILD-WITHOUT-OMNI CHECK.  4.13's rule is about
DECLARATION - does the library manifest name omni.  The proof omni's register
originally prescribed is about RESOLUTION - "CI must prove it with the
checkout absent".  Those are the same test only while omni is unfindable by
any other route, and Go left that state without anyone deciding to:
`github.com/voxgig/omni/go` resolves from proxy.golang.org today, because
omni is a public repo.  `go mod tidy` in a module with no omni checkout
anywhere resolves a pseudo-version and writes the require line.

That hole is Go's specifically - rust names omni by a literal PATH, which has
no fallback - but a declaration check earns its place in every port for a
separate reason: it catches an omni reference at the commit that introduces
it, rather than at the `go mod tidy` that publishes it.

Ported from voxgig/struct's tools/omni_isolation.py, where the same rule is
enforced across 23 ports.  Kept deliberately similar so the two can be read
against each other.

Exit status: 0 if every library manifest is clean, 1 otherwise.  Every
failure is reported, not just the first.
"""

import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Every way omni is spelled across ecosystems, including concatenated
# CamelCase (VoxgigOmni).  The separator is optional: requiring it missed
# SwiftPM's spelling entirely in the struct port of this tool.
OMNI = re.compile(r'(^|[^a-z0-9])(@?voxgig[/_.-]?omni|omni)([^a-z0-9]|$)', re.I)


def names_omni(text):
    return bool(OMNI.search(text or ''))


# THE SPELLING THAT ACTUALLY APPEARS IN CODE.
#
# Every port's source pattern used to be hand-written, and most were
# `\bomni\b` - which cannot match `voxgig_omni`, because `_` is a word
# character so there is no boundary before `omni`. That is the exact module
# name Python and Rust import. The guard would have read `import voxgig_omni`
# in a shipped file and called it clean.
#
# The mutation suite did not catch it either: the injected marker happened to
# contain a standalone `omni`. Mutation testing proves what you thought to
# mutate, and this was not thought of.
#
# One matcher now, shared with the manifest side, so the two cannot drift.
SOURCE = OMNI



def read_go_mod(path):
    """go.mod: every module path in a require, replace or exclude.

    ALL THREE HAVE A BLOCK FORM. Handling `require (` alone recorded the
    literal `replace (` and ignored every entry inside it, so an innocuously
    named module redirected to omni - `innocent/pkg => github.com/voxgig/omni/go`
    - read clean.
    """
    deps, block = [], None
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.split('//')[0].strip()
        if not line:
            continue
        if block is not None:
            if line == ')':
                block = None
            else:
                # A replace line is `old => new`; both sides matter.
                deps.append(line)
            continue
        for kw in ('require', 'replace', 'exclude'):
            if line == f'{kw} (' or line.startswith(f'{kw} ('):
                block = kw
                break
        else:
            for kw in ('require ', 'replace ', 'exclude '):
                if line.startswith(kw):
                    deps.append(line[len(kw):])
                    break
    return deps


def read_cargo(path):
    """Cargo.toml: dependencies AND dev-dependencies, keys, `package`, and
    anything inherited from `[workspace.dependencies]`.

    dev-dependencies are not exempt the way npm devDependencies are: Cargo
    resolves them even for a plain `cargo build`, which is why the conformance
    harness is a separate package.

    Three spellings hide the real crate. `runner = { package = "voxgig_omni" }`
    renames it, so the key says `runner` and code imports `runner`.
    `runner = { workspace = true }` moves the real declaration into
    `[workspace.dependencies]`, which a package-level read never sees. And a
    `[target.*]` block repeats both.
    """
    data = tomllib.loads(path.read_text(encoding='utf-8'))
    wsdeps = ((data.get('workspace') or {}).get('dependencies') or {})

    def entries(block):
        for name, spec in (block or {}).items():
            yield name
            if not isinstance(spec, dict):
                continue
            if spec.get('package'):
                yield spec['package']
            if spec.get('workspace'):
                inherited = wsdeps.get(name)
                if isinstance(inherited, dict):
                    yield inherited.get('package') or name
                    if inherited.get('git'):
                        yield str(inherited['git'])
                    if inherited.get('path'):
                        yield str(inherited['path'])
                elif isinstance(inherited, str):
                    yield inherited
            for key in ('path', 'git'):
                if spec.get(key):
                    yield str(spec[key])

    deps = []
    for block in ('dependencies', 'dev-dependencies', 'build-dependencies'):
        deps.extend(entries(data.get(block)))
    deps.extend(entries(wsdeps))
    for tgt in (data.get('target') or {}).values():
        for block in ('dependencies', 'dev-dependencies', 'build-dependencies'):
            deps.extend(entries(tgt.get(block)))
    return deps


def read_package_json(path):
    """package.json: every block EXCEPT devDependencies, keys AND values.

    devDependencies is the isolation device for the Node ports - npm never
    installs one transitively.  Values matter because
    `"runner": "npm:@voxgig/omni@1.0.0"` is an alias whose key says nothing.
    """
    data = json.loads(path.read_text(encoding='utf-8'))
    deps = []
    for block in ('dependencies', 'peerDependencies', 'optionalDependencies'):
        for name, spec in (data.get(block) or {}).items():
            deps.append(name)
            if isinstance(spec, str):
                deps.append(spec)
    return deps


def read_pyproject(path):
    """pyproject.toml, including dynamic dependency declarations."""
    data = tomllib.loads(path.read_text(encoding='utf-8'))
    proj = data.get('project') or {}
    deps = list(proj.get('dependencies') or [])
    for group in (proj.get('optional-dependencies') or {}).values():
        deps.extend(group)
    deps.extend((data.get('build-system') or {}).get('requires') or [])
    if set(proj.get('dynamic') or []) & {'dependencies', 'optional-dependencies'}:
        cfg = ((data.get('tool') or {}).get('setuptools') or {}).get('dynamic') or {}
        targets = []
        for key in ('dependencies', 'optional-dependencies'):
            spec = cfg.get(key)
            if not isinstance(spec, dict):
                continue
            if 'file' in spec:
                targets.extend(_aslist(spec['file']))
            else:
                for group in spec.values():
                    if isinstance(group, dict):
                        targets.extend(_aslist(group.get('file')))
        if not targets:
            deps.append(DYNAMIC_UNRESOLVED)
        for rel in targets:
            ref = path.parent / rel
            deps.extend(ref.read_text(encoding='utf-8').splitlines()
                        if ref.exists() else [DYNAMIC_UNRESOLVED])
    return deps


def read_csproj(path):
    """A .csproj: the Include/Update of every Package/ProjectReference.

    BOTH XML QUOTE STYLES. A double-quote-only pattern returned nothing at all
    for `Include='Voxgig.Omni'`, which is valid XML, and a package reference
    resolves whether or not any source file imports its namespace - so the
    source scan does not close that hole.

    Text-scoped rather than parsed: semgrep blocks `xml.etree` repo-wide as an
    XXE risk, and `defusedxml` would be a new dependency for a threat that
    does not exist on committed repo content.
    """
    text = path.read_text(encoding='utf-8')
    return [m.group(1) or m.group(2) for m in re.finditer(
        r'<(?:Package|Project)Reference\b[^>]*?\b(?:Include|Update)\s*='
        r'\s*(?:"([^"]*)"|\'([^\']*)\')',
        text, re.I)]


def read_composer(path):
    """composer.json: require, and the fields that stand in for it.

    require-dev is exempt: Composer never installs a dependency's require-dev.
    """
    data = json.loads(path.read_text(encoding='utf-8'))
    deps = []
    for block in ('require', 'replace', 'provide', 'conflict'):
        deps.extend((data.get(block) or {}).keys())
    return deps


def read_swift(path):
    """Package.swift, structurally - it is a PROGRAM, not a data file.

    This manifest legitimately names omni many times: it declares the
    dependency only when a gitignored symlink exists, and only for the TEST
    target.  A grep would fail on the correct tree.  So the check is
    structural: ANY package-level `.package(` that is not gated fails,
    whatever it is called, because this package publishes a library with no
    dependencies at all.
    """
    text = path.read_text(encoding='utf-8')
    fails = []
    GATE = re.compile(r'(nil\s*==\s*\w*[Oo]mni\w*|\w*[Oo]mni\w*\s*==\s*nil)'
                      r'\s*\?\s*\[\s*\]\s*:')
    m = re.search(r'\n\s*dependencies:\s*(.*?)(?=\n\s*targets:)', text, re.S)
    if m and '.package(' in m.group(1) and not GATE.search(m.group(1)):
        fails.append('package dependencies declare `.package(` with no '
                     'nil-check gate: ' + ' '.join(m.group(1).split())[:70])
    # Non-greedy to the FIRST closing paren at any indent, and `[^(]` so a
    # one-line `.target(...)` cannot run on into the `.testTarget(` below it -
    # which is what it did, reporting the correct manifest as a leak.
    for tm in re.finditer(r'\.(target|executableTarget)\(([^(]*?)\)[,\s]', text, re.S):
        if names_omni(tm.group(2)):
            fails.append(f'.{tm.group(1)} declares omni: '
                         + ' '.join(tm.group(2).split())[:70])
    return fails


def read_scoped(path, start, stop=None, exempt=None):
    """The dependency-declaring REGION of a manifest with no stdlib parser.

    A scoped textual scan, and saying so plainly matters: weaker than a parse,
    and what is available without a new dependency.  Scoped rather than a
    whole-file grep so a comment or harness stanza naming omni cannot
    false-positive.  EVERY matching region, not the first: Gradle-style files
    allow several dependency blocks, and reading one and declaring the file
    clean is a real bug this shape has had.
    """
    text = path.read_text(encoding='utf-8')
    lines = []
    for m in re.finditer(start, text, re.I | re.M):
        tail = text[m.end():]
        if stop:
            e = re.search(stop, tail, re.I | re.M)
            if e:
                tail = tail[:e.start()]
        lines.extend(line for line in tail.splitlines() if line.strip())
    if exempt:
        rx = re.compile(exempt, re.I)
        lines = [line for line in lines if not rx.search(line)]
    return lines


DYNAMIC_UNRESOLVED = ('<dynamic dependencies with no resolvable source: '
                      'omni cannot be ruled out here>')


def _aslist(value):
    if value is None:
        return []
    return [value] if isinstance(value, str) else list(value)


# `lib` is what a consumer resolves; `harness` is listed only so the output
# can say it was deliberately skipped rather than missed.
PORTS = {
    'go':         dict(lib=[('go/go.mod', read_go_mod)],
                       harness=['go/testutil/go.mod']),
    'proxy':      dict(lib=[('proxy/go.mod', read_go_mod)]),
    'rust':       dict(lib=[('rust/Cargo.toml', read_cargo)],
                       harness=['rust/corpus/Cargo.toml']),
    'csharp':     dict(lib=[('csharp/src/Station.csproj', read_csproj)],
                       harness=['csharp/test/StationTest.csproj']),
    'typescript': dict(lib=[('typescript/package.json', read_package_json)]),
    'javascript': dict(lib=[('javascript/package.json', read_package_json)]),
    'python':     dict(lib=[('python/pyproject.toml', read_pyproject)]),
    'php':        dict(lib=[('php/composer.json', read_composer)]),
    # `dependency_overrides` too: a path override is how omni would be wired
    # in without touching `dependencies`. `dev_dependencies` is exempt - pub
    # never installs a dependency's dev_dependencies, the same reason npm
    # devDependencies are exempt.
    'dart':       dict(lib=[('dart/pubspec.yaml',
                             lambda p: read_scoped(
                                 p, r'^(dependencies|dependency_overrides):',
                                 r'^[a-z_]+:'))]),
    # BOTH forms. This mix.exs declares `deps: []` inline in the project
    # keyword list, not as a `defp deps` function - and an anchor matching
    # only the function form read ZERO entries here while reporting clean.
    'elixir':     dict(lib=[('elixir/mix.exs',
                             lambda p: read_scoped(p, r'\bdeps:\s*',
                                                   r'^\s*end\b'))]),
    'swift':      dict(lib=[('swift/Package.swift', read_swift)], structural=True),

    # No manifest a consumer resolves - reported, never silently passed.
    'c':          dict(lib=[], why='header/source tree, no manifest a consumer resolves'),
    'cpp':        dict(lib=[], why='header-only, no manifest a consumer resolves'),
    'java':       dict(lib=[], why='no manifest a consumer resolves'),
    'lua':        dict(lib=[], why='no manifest a consumer resolves'),
    'perl':       dict(lib=[], why='no manifest a consumer resolves'),
    'ruby':       dict(lib=[], why='no manifest a consumer resolves'),
}

SOURCES = {
    'go':         dict(globs=['go/**/*.go'], skip=['go/testutil/'],
                       pattern=SOURCE),
    'proxy':      dict(globs=['proxy/**/*.go'], skip=[], pattern=SOURCE),
    'rust':       dict(globs=['rust/src/**/*.rs'], skip=[], pattern=SOURCE),
    'csharp':     dict(globs=['csharp/src/**/*.cs'], skip=[], pattern=SOURCE),
    'c':          dict(globs=['c/src/**/*.[ch]'], skip=[], pattern=SOURCE),
    'cpp':        dict(globs=['cpp/src/**/*.[ch]pp', 'cpp/src/**/*.h'], skip=[],
                       pattern=SOURCE),
    'dart':       dict(globs=['dart/lib/**/*.dart'], skip=[], pattern=SOURCE),
    'elixir':     dict(globs=['elixir/lib/**/*.ex'], skip=[], pattern=SOURCE),
    'java':       dict(globs=['java/src/**/*.java'], skip=['java/src/test/'],
                       pattern=SOURCE),
    'lua':        dict(globs=['lua/src/**/*.lua'], skip=[], pattern=SOURCE),
    'perl':       dict(globs=['perl/lib/**/*.pm'], skip=[], pattern=SOURCE),
    'php':        dict(globs=['php/src/**/*.php'], skip=[], pattern=SOURCE),
    'python':     dict(globs=['python/**/*.py'],
                       skip=['python/test', 'python/tests'], pattern=SOURCE),
    'ruby':       dict(globs=['ruby/lib/**/*.rb'], skip=[], pattern=SOURCE),
    'swift':      dict(globs=['swift/Sources/**/*.swift'], skip=[], pattern=SOURCE),
    # omnihome.* is the OMNI_HOME resolver: it lives in src/ but is excluded
    # from the package by a `files` negation, which is the isolation device
    # here and is asserted separately below.
    'typescript': dict(globs=['typescript/src/**/*.ts'],
                       skip=['typescript/src/omnihome'], pattern=SOURCE),
    'javascript': dict(globs=['javascript/src/**/*.js'],
                       skip=['javascript/src/omnihome'], pattern=SOURCE),
}


# A WHOLE-LINE comment is skipped; a trailing one is not.
#
# These ports discuss omni in prose constantly - what the runner is, why a
# dependency is a test one, which convention a helper follows - and a bare
# mention is not a reference. Scanning them anyway produced eleven findings
# across nine ports, every one a comment, which is how a guard trains people
# to ignore it.
#
# Deliberately narrow: only a line whose FIRST non-space characters are a
# comment marker. A real reference with a trailing comment is still read, and
# so is anything inside a string.
COMMENT = re.compile(r'^\s*(//|#|--|\*|/\*|"""|\'\'\')')


def is_comment(line):
    return bool(COMMENT.match(line))


def scan_sources(port):
    spec = SOURCES.get(port)
    if not spec:
        return [], 0
    rx = spec['pattern']
    hits, seen = [], 0
    for glob in spec['globs']:
        for path in ROOT.glob(glob):
            rel = path.relative_to(ROOT).as_posix()
            if any(rel.startswith(s) for s in spec['skip']):
                continue
            seen += 1
            try:
                text = path.read_text(encoding='utf-8', errors='replace')
            except OSError:
                continue
            for n, line in enumerate(text.splitlines(), 1):
                if is_comment(line):
                    continue
                if rx.search(line):
                    hits.append(f'{rel}:{n}: {line.strip()[:70]}')
    return hits, seen


def discover_ports():
    """Every port directory, found rather than listed.

    A port here carries its own Makefile.  Discovering them is the point: a
    port absent from both tables is a port nothing checks, and in the struct
    port of this tool exactly that happened - a whole language was missed
    while the output said everything was clean.
    """
    skip = {'tools', 'spec', 'test', 'docs', 'sdkgen-station'}
    manifests = ('go.mod', 'Cargo.toml', 'pubspec.yaml', 'mix.exs',
                 'composer.json', 'pyproject.toml', 'package.json',
                 'Package.swift')
    found = set()
    for entry in ROOT.iterdir():
        if not entry.is_dir() or entry.name.startswith('.') or entry.name in skip:
            continue
        # A Makefile OR a manifest. Not the Makefile alone: `typescript/` has
        # no Makefile in this repo, and keying on one alone reported it as a
        # STALE entry - the discovery check accusing a real port of not
        # existing, which is the same class of error as missing one.
        if (any((entry / n).exists() for n in ('Makefile', 'makefile'))
                or any((entry / m).exists() for m in manifests)):
            found.add(entry.name)
    return found


def main():
    fails, uncovered, checked = [], [], []

    # BOTH tables, not their union. A port listed in only one is still
    # "known", so neither check fires while half its scanning is silently
    # skipped. A port with no manifest declares `lib=[]` explicitly; there is
    # no opting out of SOURCES.
    ports = discover_ports()
    for port in sorted(ports - set(PORTS)):
        fails.append(f'{port}: is a port directory with no PORTS entry - its '
                     'manifests are unchecked; add one (lib=[] with a `why` if '
                     'it has no manifest a consumer resolves)')
    for port in sorted(ports - set(SOURCES)):
        fails.append(f'{port}: is a port directory with no SOURCES entry - its '
                     'shipped source is unscanned; add one')
    for port in sorted((set(PORTS) | set(SOURCES)) - ports):
        fails.append(f'{port}: has an entry here but is not a port directory - '
                     'stale, and its checks read nothing')

    for port in sorted(PORTS):
        spec = PORTS[port]
        if not spec['lib']:
            uncovered.append((port, spec.get('why', 'no manifest')))
            continue
        for relpath, reader in spec['lib']:
            path = ROOT / relpath
            if not path.exists():
                fails.append(f'{port}: {relpath} is missing - has the port moved?')
                continue
            try:
                found = reader(path)
            except Exception as err:                     # noqa: BLE001
                fails.append(f'{port}: could not read {relpath}: {err!r}')
                continue
            checked.append(relpath)
            if spec.get('structural'):
                # The reader returns failures directly, not dependency names.
                for f in found:
                    fails.append(f'{port}: {relpath}: {f}')
            else:
                for dep in found:
                    if names_omni(dep):
                        fails.append(f'{port}: {relpath} declares omni: '
                                     + ' '.join(str(dep).split())[:80])

    # A glob matching NOTHING is a failure, not a pass.
    scanned = 0
    for port in sorted(SOURCES):
        hits, seen = scan_sources(port)
        scanned += seen
        if 0 == seen:
            fails.append(f'{port}: source globs matched NO files '
                         f'({SOURCES[port]["globs"]}) - the scan is checking '
                         'nothing; fix the glob')
        for hit in hits:
            fails.append(f'{port}: shipped source names omni: {hit}')

    print(f'omni register 4.13 - library manifests checked: {len(checked)}, '
          f'shipped source files scanned: {scanned}')
    for port, why in uncovered:
        print(f'  UNCOVERED  {port}: {why}')

    if fails:
        print('\nstation: omni is named by something a consumer resolves\n',
              file=sys.stderr)
        for f in fails:
            print(f'  {f}', file=sys.stderr)
        return 1

    print('  all clean')
    return 0


if __name__ == '__main__':
    sys.exit(main())
