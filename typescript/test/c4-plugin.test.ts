// RUN: npm test   (or: make test-c4 at the repo root)
//
// C4a/C4b (plugin/doc/plan/contracts.md): station runs voxgig/plugin's
// corpus sections - `ref` + `config` (C4a) and `lifecycle` + `order`
// (C4b) - from the sibling checkout's spec/plugin.json against
// STATION'S OWN implementation, and reports divergence as a plugin
// issue rather than absorbing it.
//
// THREE MANIFESTS ARE THE DELIVERABLE, and all three are load-bearing:
//
// - SKIP_GROUPS / SKIP_ENTRIES pin what station has NO genuine
//   counterpart for, each with the reason. The adapters raise
//   NoCounterpart on that vocabulary, so an entry missing from the
//   manifest fails instead of half-running - and the dispatch test
//   fails on any corpus group that is neither mapped nor skipped, so a
//   new plugin section group cannot arrive silently.
// - DIVERGE pins the entries where station's implementation DISAGREES
//   with plugin's corpus today. Each row is asserted to STILL FAIL:
//   fixing a divergence forces removing its row, and a row that stops
//   failing without a fix is a corpus change worth noticing. These
//   rows are the "report as a plugin issue" half of C4.
//
// Nothing here reimplements plugin. The subjects are station's own
// exports - instanceRef (Station.ts), resolveProfile (profile.ts),
// resolveorder/checkpin (feature.ts) - reached through adapters that
// translate INPUT vocabulary only (test/c4/*.ts state every mapping).

import { test } from 'node:test'
import * as Assert from 'node:assert'

import {
  checkInstanceName, checkInstanceTag, instanceRef,
} from '../src/Station'
import { refapi } from '../src/profile'

import {
  CodeMap, Entry, check, label, pluginhome, section,
} from './c4/corpus'
import { normsubject, optsubject, xnormentry } from './c4/config'
import { ORDER_CODES, drive, xorderentry } from './c4/driver'

// ---------------------------------------------------------------------
// The skip manifest: no station counterpart, and why
// ---------------------------------------------------------------------

const SKIP_GROUPS: { [sectionGroup: string]: string } = {
  // -- ref (C4a): station adopted the joint ref grammar (Station.ts
  // checkInstanceName/checkInstanceTag, canonicalization in
  // instanceRef's checkref) - which discharged this section's former
  // DIVERGE rows. One group remains unmappable:
  'ref/parse':
    'station has no (name, tag) PAIR builder: refapi() extracts the name ' +
    'half and validation/canonicalization live inside instanceRef; the ' +
    'grammar itself is covered by name/tag/bound/boundtag/canon/parsebad',

  // -- config (C4a): outside the joint agreement's documented mapping.
  'config/normarray':
    'the array (positional) instance form: station\'s config grammar has ' +
    'only the map form (sdk/api maps), and the group\'s map-form entry ' +
    'pins `stripe$` canonicalization, which station also lacks',
  'config/normreserved':
    'reserved instance refs: station\'s reservation is feature.station in ' +
    'the FEATURE namespace (joint doc §3.3), not a bar on sdk/api refs; ' +
    'the `reserved` input has no station spelling',
  'config/optmerge':
    '$MERGE shape vocabulary: station declares no per-key merge - its ' +
    'depth rules are fixed by design (§3.3 shallow per block key, ' +
    'joint doc §2.5 pins `options`/`policy` as replace; the feature map\'s ' +
    'two-level rule lives in mergefeatures, keyed by block, not by a ' +
    'shape directive) - and the no-shape entries pin plugin\'s ' +
    'library-default deep merge INSIDE options, which §2.5 records ' +
    'station deliberately not sharing',
  'config/optmergebad':
    'checkshape/$MERGE validation: station has no $MERGE vocabulary to ' +
    'validate',

  // -- order (C4b)
  'order/pinorder':
    'a multi-name pin map ({noisy: first, probe: first}): station\'s pin ' +
    'machinery is checkpin - exactly one name (`station`), innermost; ' +
    'there is no `first` pin and no pin map to sort',

  // -- lifecycle (C4b): no native counterpart until the P3
  // bridge/library swap. Station's native phase has no probe catalog,
  // no status ladder (declared/loaded/pending/live/failed), no
  // instance scope, and no callback log - features bind through the
  // generated SDK, and station's lifecycle slice is instance
  // activation (`active`, station_instance_inactive), covered by its
  // own corpus and suites. Per-group, what each pins:
  'lifecycle/forward': 'the declared->loaded->live staircase',
  'lifecycle/back': 'deactivate/unload transitions and state survival',
  'lifecycle/idem': 'idempotent transitions on the status ladder',
  'lifecycle/illegal': 'plugin_not_loaded/plugin_ref_duplicate state errors',
  'lifecycle/fail': 'the failed status staying registered and inspectable',
  'lifecycle/faildown': 'failures during teardown callbacks',
  'lifecycle/failedexit': 'exiting the failed status',
  'lifecycle/wrap': 'plugin_<phase>_failed wrapping of bare callback raises',
  'lifecycle/bindscope': 'plugin_bind_scope - bindings declared outside define',
  'lifecycle/resource': 'the instance scope and its reverse unwind (§8.3)',
  'lifecycle/pending': 'capability-gated activation (pending status)',
  'lifecycle/reentrant': 'reentrant transitions from inside callbacks',
  'lifecycle/introspect': 'the status map observable (host.list)',
  'lifecycle/slow': 'the probe catalog itself (slow is a plain probe)',
}

const SKIP_ENTRIES: { [entryLabel: string]: string } = {
  // -- config: entries inside mapped groups that reach for vocabulary
  // the §3.2 table does not cover.
  //
  // (a) plugin's library-default merge INSIDE options across levels:
  // station's `options` block key replaces wholesale (§3.3 shallow per
  // key; joint doc §2.5 records the difference and its resolution -
  // merge depth is the shape's to declare, and station declares
  // replace). Translating these expectations would mean this adapter
  // applying a merge rule, i.e. absorbing the difference.
  'config/optdefault@4':
    'per-key merge of default.options into instance.options; station\'s ' +
    'options block replaces wholesale (joint doc §2.5)',
  'config/optprofile@2':
    'per-key merge of base options into overlay options; same §2.5 rule',
  'config/optlist@2':
    'library-default deep merge of a map-valued option across levels; ' +
    'same §2.5 rule',
  // (b) ladder levels 1-2 and 7-10, which the §3.2 table does not map
  // (station has no definition shape defaults, host defaults, env
  // option layer, host/load options, or runtime patch in its resolver).
  'config/optladder#1': 'level 1 (definition shape defaults)',
  'config/optladder@1': 'level 2 (hostdefaults)',
  'config/optladder@2': 'level 2 (hostdefaults)',
  'config/optladder@6': 'level 7 (env)',
  'config/optladder@7': 'levels 7-8 (env, hostoptions)',
  'config/optladder@8': 'levels 8-9 (hostoptions, loadoptions)',
  'config/optladder@9': 'levels 9-10 (loadoptions, patch)',
  'config/optladder#7-beats-6': 'level 7 (env)',
  'config/optladder@11': 'level 7 (env)',
  'config/optladder@12': 'levels 1 and 10 (shape, patch)',
  'config/optladder@13': 'levels 2 and 8 (hostdefaults, hostoptions)',
  'config/optladder@14': 'level 9 (loadoptions)',
  'config/optladder@16': 'levels 1 and 7 (shape, env)',
  'config/optladder#all-ten': 'levels 1-2 and 7-10',
  'config/optladder@18': 'levels 1-2 and 7-9',
  'config/optlist@1': 'level 10 (patch)',
  // (c) the layered/positional normalized form.
  'config/normmap#pos':
    'positional `pos` on instances: station\'s registry is a keyed map, ' +
    'not positional',
  'config/normmap#bytewise':
    'mixed-case sibling refs (`A` beside `a`): station\'s own credential ' +
    'layer bars the document - envtoken is case-lossy, so both derive ' +
    'a.apikey and station_secret_collision fires (§5.1). That layer is ' +
    'deliberately station\'s own (joint doc §3.3), not shared semantics; ' +
    'the cost is that the byte-wise-vs-folded sort question this entry ' +
    'discriminates is unreachable here (the all-lowercase order entries ' +
    'still run)',
  'config/normdefaults@1':
    '`start` (eager/lazy) has no station config vocabulary',
  'config/normdefaults@2':
    '`start` (eager/lazy) has no station config vocabulary',
  'config/normdefaults@3':
    'a nested instance map inside options (nested-host vocabulary, a P3 ' +
    'bridge concern) and a multi-layer optionlayers expectation',
  'config/normkeys@2':
    'a multi-layer optionlayers expectation: station resolves layers ' +
    'immediately (§2.5), so the unmerged list has no counterpart',
  'config/normpartial#keep':
    'an array-form overlay and its positional overlay-first order; ' +
    'station has only the map form',
  'config/normpartial@1': 'an array-form overlay; station has only the map form',
  'config/normpartial#arrayoptions':
    'an array-form overlay and a multi-layer optionlayers expectation',

  // -- order
  'order/pin@2':
    'an `outermost` pin: station\'s checkpin pins exactly one name ' +
    '(`station`) innermost; there is no outermost pin',
}

// ---------------------------------------------------------------------
// The divergence manifest: station disagrees TODAY, and each row is
// asserted to still fail. Fixing station (or plugin) forces removing
// the row; these rows are what C4 reports upstream as plugin issues.
// ---------------------------------------------------------------------

const DIVERGE: { [entryLabel: string]: string } = {
  // EMPTY, and that is the news: the eight rows this manifest carried
  // (instanceRef accepting every name and tag plugin's §4 grammar
  // rejects) were discharged by station adopting the joint ref grammar
  // in Station.ts - checkref inside instanceRef, with the corpus's
  // instanceref section pinning the canonical/refused cases. New
  // divergences land here, each asserted to still-fail until fixed.
}

// ---------------------------------------------------------------------
// Section wiring: group -> station subject
// ---------------------------------------------------------------------

/** plugin code -> station code where a mapped entry expects a raise
 * station spells with its own §14 code. See c4/corpus.ts CodeMap. */
const REF_CODES: CodeMap = {
  // Station spells every ref-grammar refusal station_instance_api:
  // checkref (name/tag grammar, joint doc §2/§4) and checkapi (a full
  // ref naming a different api, §6.1) are one error family.
  plugin_bad_name: 'station_instance_api',
  plugin_bad_tag: 'station_instance_api',
}

type SectionSpec = {
  name: string
  codemap: CodeMap
  xentry: (e: Entry) => Entry
  subjectfor: (group: string) => ((e: Entry) => any) | null
}

const REF_SUBJECTS: { [group: string]: (e: Entry) => any } = {
  // formatref(name, tag) -> instanceRef(api, {as: tag}): station's
  // formatter. `as` is a tag when `$`-less and a validated full ref
  // otherwise (§6.1), which for the corpus's always-a-tag arguments is
  // the same join; bad input now refuses through checkref.
  format: (e) => instanceRef((e.args as any[])[0], { as: (e.args as any[])[1] }),
  formatbad: (e) => instanceRef((e.args as any[])[0], { as: (e.args as any[])[1] }),
  // canonref/parseref(bad) -> instanceRef(refapi(ref), {instance: ref}):
  // station's canonicalization and grammar refusal live inside
  // instanceRef, so the api argument is derived from the ref's own name
  // half - which makes checkapi vacuous and leaves checkref the subject.
  canon: (e) => instanceRef(refapi(e.in), { instance: e.in }),
  parsebad: (e) => instanceRef(refapi(e.in), { instance: e.in }),
  // checkname/checktag -> the exported predicates.
  name: (e) => checkInstanceName(e.in),
  tag: (e) => checkInstanceTag(e.in),
  bound: (e) => checkInstanceName(e.in),
  boundtag: (e) => checkInstanceTag(e.in),
}

const identity = (e: Entry): Entry => e

const SECTIONS: SectionSpec[] = [
  {
    name: 'ref',
    codemap: REF_CODES,
    xentry: identity,
    subjectfor: (g) => REF_SUBJECTS[g] || null,
  },
  {
    name: 'config',
    codemap: {},
    // norm* expectations carry single-layer optionlayers, translated
    // losslessly to resolved options (c4/config.ts says why).
    xentry: (e) => xnormentry(e),
    subjectfor: (g) => {
      if (g.startsWith('norm')) { return normsubject }
      if (g.startsWith('opt')) { return optsubject }
      return null
    },
  },
  {
    name: 'lifecycle',
    codemap: {},
    xentry: identity,
    subjectfor: () => null,
  },
  {
    name: 'order',
    codemap: ORDER_CODES,
    xentry: (e) => xorderentry(e),
    subjectfor: () => (e: Entry) => drive(e.cmd as any[]),
  },
]

// ---------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------

const HOME = pluginhome()

if (null == HOME) {
  if (process.env.STATION_REQUIRE_C4) {
    test('c4-plugin: checkout required', () => {
      throw new Error(
        'STATION_REQUIRE_C4 is set but no voxgig/plugin checkout was ' +
        'found (spec/plugin.json) - set PLUGIN_HOME or add a sibling ' +
        'checkout; C4 must run, not skip, where this variable is set')
    })
  }
  else {
    test('c4-plugin: no plugin checkout - skipped', (t: any) => {
      t.skip('set PLUGIN_HOME or place a voxgig/plugin sibling checkout ' +
        'to run the C4 conformance suite')
    })
  }
}
else {
  const home: string = HOME
  const loaded: { [name: string]: { [group: string]: Entry[] } } = {}
  for (const s of SECTIONS) { loaded[s.name] = section(home, s.name) }

  // Every group is dispatched or skipped - a group the runner does not
  // know is a group silently not run, which is worse than a failure
  // (plugin's own runners carry the same test).
  test('c4-plugin: every group is mapped or skipped', () => {
    const unknown: string[] = []
    for (const s of SECTIONS) {
      for (const g of Object.keys(loaded[s.name])) {
        if (SKIP_GROUPS[s.name + '/' + g]) { continue }
        if (null == s.subjectfor(g)) { unknown.push(s.name + '/' + g) }
      }
    }
    Assert.deepEqual(unknown, [],
      'corpus groups with no subject and no skip row: ' + unknown.join(', '))
  })

  // The manifests may only name things that exist - a corpus change
  // that renames or removes an entry forces the row to move with it.
  test('c4-plugin: manifest rows resolve', () => {
    const groups = new Set<string>()
    const labels = new Set<string>()
    const skippedgroup = (lab: string): boolean => {
      for (const g of Object.keys(SKIP_GROUPS)) {
        const sec = g.substring(0, g.indexOf('/'))
        const grp = g.substring(g.indexOf('/') + 1)
        const set = loaded[sec] && loaded[sec][grp]
        if (set && set.some((e, i) => label(sec, grp, i, e) === lab)) { return true }
      }
      return false
    }
    for (const s of SECTIONS) {
      for (const g of Object.keys(loaded[s.name])) {
        groups.add(s.name + '/' + g)
        loaded[s.name][g].forEach((e, i) => labels.add(label(s.name, g, i, e)))
      }
    }
    const bad: string[] = []
    for (const g of Object.keys(SKIP_GROUPS)) {
      if (!groups.has(g)) { bad.push('SKIP_GROUPS: ' + g) }
    }
    for (const l of Object.keys(SKIP_ENTRIES)) {
      if (!labels.has(l)) { bad.push('SKIP_ENTRIES: ' + l) }
      else if (skippedgroup(l)) { bad.push('SKIP_ENTRIES (group already skipped): ' + l) }
    }
    for (const l of Object.keys(DIVERGE)) {
      if (!labels.has(l)) { bad.push('DIVERGE: ' + l) }
      else if (SKIP_ENTRIES[l] || skippedgroup(l)) {
        bad.push('DIVERGE (also skipped): ' + l)
      }
    }
    Assert.deepEqual(bad, [], 'stale or contradictory manifest rows:\n' + bad.join('\n'))
  })

  const tally = { pass: 0, skip: 0, diverge: 0 }

  for (const s of SECTIONS) {
    for (const g of Object.keys(loaded[s.name])) {
      const key = s.name + '/' + g

      if (SKIP_GROUPS[key]) {
        test('c4-plugin ' + key + ' [skipped]', (t: any) => {
          tally.skip += loaded[s.name][g].length
          t.skip(SKIP_GROUPS[key])
        })
        continue
      }

      test('c4-plugin ' + key, () => {
        const subject = s.subjectfor(g)
        if (null == subject) { return }
        const fails: string[] = []

        loaded[s.name][g].forEach((e, i) => {
          const lab = label(s.name, g, i, e)
          if (SKIP_ENTRIES[lab]) { tally.skip += 1; return }

          const why = check(s.xentry(e), subject, s.codemap)

          if (DIVERGE[lab]) {
            tally.diverge += 1
            if (null == why) {
              fails.push(lab + ': DIVERGENCE RESOLVED - station now agrees ' +
                'with the corpus; remove the DIVERGE row (' + DIVERGE[lab] + ')')
            }
            return
          }
          if (why) { fails.push(lab + ': ' + why) }
          else { tally.pass += 1 }
        })

        Assert.deepEqual(fails, [], '\n' + fails.join('\n'))
      })
    }
  }

  test('c4-plugin: totals', (t: any) => {
    t.diagnostic('c4 conformance: ' + tally.pass + ' pass, ' +
      tally.diverge + ' pinned divergences, ' + tally.skip + ' skipped ' +
      '(plugin checkout: ' + home + ')')
    Assert.ok(0 < tally.pass, 'the mapped set must not be empty')
    Assert.equal(tally.diverge, Object.keys(DIVERGE).length,
      'every DIVERGE row was exercised')
  })
}
