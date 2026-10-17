#!/usr/bin/env python3
"""Plan a station release: what each port needs to reach the version in VERSION.

    python3 tools/release_plan.py                       # print the plan
    python3 tools/release_plan.py --pushed-tag go/v0.3.0 --github-output FILE

Every port with a release route ships at VERSION from one commit. A port
already released at VERSION is left alone only while its directory is
unchanged since its tag, so one version never names two trees of a port.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = 'https://registry.npmjs.org'

NPM_PORTS = ('typescript', 'javascript')
TAG_PORTS = ('go',)
PORTS = NPM_PORTS + TAG_PORTS

PUBLISH = ('publish', 'publish+tag')
TAG = ('tag', 'publish+tag')


class Refusal(Exception):
    pass


def decide(port, tag, head, at, same_tree, registry, warn):
    """The state of one port.

    `at` is the commit `tag` points at, or None. `registry` is None for a
    port released by its tag alone, else (published, source commit or '').
    """
    if registry is None:
        if at is None:
            return 'tag'
        if at == head or same_tree(at):
            return 'done'
        raise Refusal('%s changed since %s was tagged on %s; bump VERSION'
                      % (port, tag, at[:12]))

    published, source = registry
    if published and at:
        if source and source != at:
            raise Refusal('npm built %s from %s, but %s points at %s'
                          % (tag, source[:12], tag, at[:12]))
        if at == head or same_tree(at):
            return 'done'
        raise Refusal('%s changed since %s was released on %s; bump VERSION'
                      % (port, tag, at[:12]))
    if published:
        if not source:
            warn('npm records no source commit for %s; cannot verify it was '
                 'built from this commit' % tag)
        elif source != head:
            raise Refusal('npm has %s built from %s, not this commit %s; push '
                          'the tag on %s to finish that release'
                          % (tag, source[:12], head[:12], source[:12]))
        return 'tag'
    if at:
        if at == head:
            return 'publish'
        raise Refusal('%s already points at %s, but npm has no such version'
                      % (tag, at[:12]))
    return 'publish+tag'


def plan(version, head, pushed, tag_at, same_tree, registry_of, warn):
    if pushed and pushed not in ['%s/v%s' % (p, version) for p in PORTS]:
        raise Refusal('pushed tag %s is not a port tag for VERSION %s'
                      % (pushed, version))
    states = {}
    for port in PORTS:
        tag = '%s/v%s' % (port, version)
        registry = registry_of(port, version) if port in NPM_PORTS else None
        states[port] = decide(port, tag, head, tag_at(tag),
                              lambda c, p=port: same_tree(p, c), registry, warn)
    return states


def git(*args):
    return subprocess.run(['git'] + list(args), cwd=ROOT,
                          capture_output=True, text=True)


def tag_at(tag):
    r = git('rev-parse', '-q', '--verify', 'refs/tags/%s^{commit}' % tag)
    return r.stdout.strip() if 0 == r.returncode else None


def same_tree(port, commit):
    return 0 == git('diff', '--quiet', commit, 'HEAD', '--', port + '/').returncode


def fetch_json(url):
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if 404 == e.code:
            return None
        raise


def provenance_commit(url):
    doc = fetch_json(url) or {}
    for a in doc.get('attestations', []):
        if not a.get('predicateType', '').startswith('https://slsa.dev/provenance/'):
            continue
        payload = a['bundle']['dsseEnvelope']['payload']
        pred = json.loads(base64.b64decode(payload)).get('predicate', {})
        for dep in pred.get('buildDefinition', {}).get('resolvedDependencies', []):
            if dep.get('digest', {}).get('gitCommit'):
                return dep['digest']['gitCommit']
        for mat in pred.get('materials', []):
            if mat.get('digest', {}).get('sha1'):
                return mat['digest']['sha1']
    return ''


def registry_of(port, version):
    with open(os.path.join(ROOT, port, 'package.json'), encoding='utf-8') as f:
        name = json.load(f)['name']
    doc = fetch_json('%s/%s/%s' % (REGISTRY, urllib.parse.quote(name, safe='@'),
                                   version))
    if doc is None:
        return (False, '')
    if doc.get('gitHead'):
        return (True, doc['gitHead'])
    url = doc.get('dist', {}).get('attestations', {}).get('url')
    return (True, provenance_commit(url) if url else '')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--pushed-tag', default='')
    ap.add_argument('--github-output')
    args = ap.parse_args(argv)

    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import version as versions
    version = versions.shared(ROOT)
    head = git('rev-parse', 'HEAD').stdout.strip()

    def warn(msg):
        print('::warning::' + msg)

    registry = {p: registry_of(p, version) for p in NPM_PORTS}
    for port in PORTS:
        tag = '%s/v%s' % (port, version)
        facts = []
        if tag_at(tag):
            facts.append('tagged on %s' % tag_at(tag)[:12])
        if registry.get(port, (False,))[0]:
            facts.append('npm built it from %s'
                         % (registry[port][1][:12] or 'an unrecorded commit'))
        print('%-11s %-22s %s' % (port, tag, ', '.join(facts) or 'unreleased'))

    try:
        states = plan(version, head, args.pushed_tag, tag_at, same_tree,
                      lambda port, _v: registry[port], warn)
    except Refusal as e:
        print('::error::%s' % e)
        return 1

    publish = [p for p in NPM_PORTS if states[p] in PUBLISH]
    tags = ['%s/v%s' % (p, version) for p in PORTS if states[p] in TAG]
    print('\nfrom %s:' % head[:12])
    for port in PORTS:
        print('  %-11s %s' % (port, states[port]))
    if not publish and not tags:
        print('every port is released at %s; nothing to do' % version)

    if args.github_output:
        with open(args.github_output, 'a', encoding='utf-8') as f:
            f.write('version=%s\n' % version)
            f.write('publish=%s\n' % json.dumps(publish))
            f.write('tags=%s\n' % ' '.join(tags))
            f.write('go=%s\n' % ('true' if 'tag' == states['go'] else 'false'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
