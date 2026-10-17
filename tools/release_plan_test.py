#!/usr/bin/env python3
"""Every state tools/release_plan.py can reach, and every refusal."""

import importlib.util
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    'release_plan', os.path.join(ROOT, 'tools', 'release_plan.py'))
RP = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RP)

HEAD = 'h' * 40
OLD = 'o' * 40
OTHER = 'x' * 40


def decide(at, registry, same=True):
    warnings = []
    state = RP.decide('p', 'p/v1.0.0', HEAD, at, lambda c: same, registry,
                      warnings.append)
    return state, warnings


class Decide(unittest.TestCase):

    def test_tag_port(self):
        self.assertEqual('tag', decide(None, None)[0])
        self.assertEqual('done', decide(HEAD, None, same=False)[0])
        self.assertEqual('done', decide(OLD, None)[0])
        with self.assertRaisesRegex(RP.Refusal, 'changed since'):
            decide(OLD, None, same=False)

    def test_released(self):
        self.assertEqual('done', decide(HEAD, (True, HEAD))[0])
        self.assertEqual('done', decide(OLD, (True, OLD))[0])
        self.assertEqual('done', decide(OLD, (True, ''))[0])
        with self.assertRaisesRegex(RP.Refusal, 'changed since'):
            decide(OLD, (True, OLD), same=False)
        with self.assertRaisesRegex(RP.Refusal, 'npm built'):
            decide(OLD, (True, OTHER))

    def test_published_untagged(self):
        self.assertEqual(('tag', []), decide(None, (True, HEAD)))
        state, warnings = decide(None, (True, ''))
        self.assertEqual('tag', state)
        self.assertEqual(1, len(warnings))
        with self.assertRaisesRegex(RP.Refusal, 'not this commit'):
            decide(None, (True, OLD))

    def test_unpublished(self):
        self.assertEqual('publish', decide(HEAD, (False, ''))[0])
        self.assertEqual('publish+tag', decide(None, (False, ''))[0])
        with self.assertRaisesRegex(RP.Refusal, 'npm has no such version'):
            decide(OLD, (False, ''))


class Plan(unittest.TestCase):

    def run_plan(self, pushed='', tags=None, registry=None, changed=()):
        tags = tags or {}
        registry = registry or {}
        return RP.plan('1.0.0', HEAD, pushed, tags.get,
                       lambda port, c: port not in changed,
                       lambda port, v: registry.get(port, (False, '')),
                       lambda msg: None)

    def test_first_release(self):
        self.assertEqual({'typescript': 'publish+tag',
                          'javascript': 'publish+tag',
                          'go': 'tag'}, self.run_plan())

    def test_bringing_lagging_ports_up(self):
        states = self.run_plan(tags={'typescript/v1.0.0': OLD},
                               registry={'typescript': (True, OLD)})
        self.assertEqual({'typescript': 'done', 'javascript': 'publish+tag',
                          'go': 'tag'}, states)

    def test_a_changed_released_port_refuses_the_whole_run(self):
        with self.assertRaisesRegex(RP.Refusal, 'typescript changed since'):
            self.run_plan(tags={'typescript/v1.0.0': OLD},
                          registry={'typescript': (True, OLD)},
                          changed=('typescript',))

    def test_pushed_tag(self):
        states = self.run_plan(pushed='go/v1.0.0', tags={'go/v1.0.0': HEAD})
        self.assertEqual('done', states['go'])
        self.assertEqual('publish+tag', states['typescript'])
        with self.assertRaisesRegex(RP.Refusal, 'not a port tag'):
            self.run_plan(pushed='go/v1.0.1')
        with self.assertRaisesRegex(RP.Refusal, 'not a port tag'):
            self.run_plan(pushed='python/v1.0.0')

    def test_everything_released(self):
        tags = {'%s/v1.0.0' % p: HEAD for p in RP.PORTS}
        registry = {p: (True, HEAD) for p in RP.NPM_PORTS}
        self.assertEqual({p: 'done' for p in RP.PORTS},
                         self.run_plan(tags=tags, registry=registry))


if __name__ == '__main__':
    unittest.main()
