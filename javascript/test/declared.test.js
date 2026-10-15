// A port of the declared-options-and-feature-schema suite in
// typescript/test/declarative.test.ts, which is canonical.

const { describe, test } = require('node:test')
const { deepStrictEqual, equal, ok, throws } = require('node:assert')

const { Station } = require('../src/Station')
const { featureBinding } = require('../src/adapter')
const { provide, resetFactories } = require('../src/factory')

const NOTES = {
  base: 'http://127.0.0.1:9',
  options: { headers: { 'x-api-version': '2022-06-28' }, prefix: '/v1' },
}

function station(sdk) {
  return new Station({
    config: { station: 1, profiles: { default: { sdk } } },
    proxy: 'off', load: false,
  })
}

function recorder() {
  const seen = []
  class NotesSDK {
    constructor(o) {
      const { feature: _f, extend: _e, ...rest } = o
      seen.push(rest)
    }
  }
  return { NotesSDK, seen }
}

// Binds through the adapter, the way a generated SDK does.
function bindingSDK(slug, feature) {
  const config = {
    main: { slug, name: slug, version: '1.0.0' },
    options: { auth: { prefix: 'Bearer ' }, server: {} },
    entity: {},
    ...(null == feature ? {} : { feature }),
  }
  class SDK {
    constructor(options) {
      this.options = options
      this._features = [{ name: 'station' }]
      this._mode = 'test'
      featureBinding({
        client: this,
        utility: { fetcher: async () => ({ status: 200 }) },
        options: { feature: {} },
        config,
      }, options.feature.station)
    }
  }
  return { config, SDK }
}

describe('declared-options-and-feature-schema', () => {

  test('connect and adopt hand a named instance its declared options', () => {
    const st = station({ notes: NOTES })
    const { NotesSDK, seen } = recorder()

    st.connect(NotesSDK, { instance: 'notes' })
    st.adopt(NotesSDK, { instance: 'notes' })
    st.connect(NotesSDK, { feature: { station: { instance: 'notes' } } })

    equal(seen.length, 3)
    for (const one of seen) {
      deepStrictEqual(one, {
        base: 'http://127.0.0.1:9',
        headers: { 'x-api-version': '2022-06-28' },
        prefix: '/v1',
      })
    }
    st.close()
  })

  test('the caller wins per top-level key, as in build()', () => {
    const st = station({ notes: NOTES })
    const { NotesSDK, seen } = recorder()

    st.connect(NotesSDK, {
      as: 'notes$', headers: { 'x-caller': 'yes' }, suffix: '.json',
    })
    deepStrictEqual(seen[0], {
      base: 'http://127.0.0.1:9',
      headers: { 'x-caller': 'yes' },
      prefix: '/v1',
      suffix: '.json',
    })
    st.close()
  })

  test('options() hands a named instance its declared options too', () => {
    const st = station({ notes: NOTES })

    const { feature: _f, ...named } = st.options('notes', { suffix: '.json' })
    deepStrictEqual(named, {
      base: 'http://127.0.0.1:9',
      headers: { 'x-api-version': '2022-06-28' },
      prefix: '/v1',
      suffix: '.json',
    })

    const { feature: _g, ...unnamed } = st.options({ suffix: '.json' })
    deepStrictEqual(unnamed, { suffix: '.json' })
    st.close()
  })

  test('options() names the instance from a top-level instance or as, as connect does', () => {
    const notes = bindingSDK('notes')
    const blocks = { notes: NOTES, 'notes$eu': { options: { prefix: '/eu' } } }

    for (const named of [{ instance: 'notes$eu' }, { as: 'notes$eu' }]) {
      const st = station(blocks)
      const built = st.options({ ...named, suffix: '.json' })
      const { feature: _f, ...sdkopts } = built
      deepStrictEqual(sdkopts, { prefix: '/eu', suffix: '.json' })

      new notes.SDK(built)
      deepStrictEqual(st.plugins().map((p) => p.name), ['notes$eu'])
      st.close()
    }
  })

  test('an unnamed connect cannot apply them, and says so', () => {
    const notes = bindingSDK('notes')
    const st = station({ notes: NOTES })

    const client = st.connect(notes.SDK, { prefix: '/mine' })
    equal(client.options.headers, undefined)

    const warns = st.events()
      .filter((e) => 'notes' === e.plugin && null != e.meta?.warn)
      .map((e) => e.meta.warn)
    equal(warns.length, 1)
    ok(warns[0].includes('[headers]'), warns[0])
    ok(warns[0].includes('{ instance: "notes" }'), warns[0])
    st.close()
  })

  test('sdk() takes the test feature options its optspec declares', () => {
    resetFactories()
    try {
      const joplin = bindingSDK('joplin', {
        test: {
          options: { active: false },
          optspec: { entity: '`$MAP`', net: '`$MAP`' },
          strict: false,
          transport: 'base',
        },
      })
      provide('joplin', { construct: (o) => new joplin.SDK(o), config: joplin.config })

      for (const test of [
        { active: true, entity: { note: {} } },
        { active: true, net: { offline: true } },
      ]) {
        const st = station({ joplin: { feature: { test } } })
        st.sdk('joplin')
        st.close()
      }

      const st = station({ joplin: { feature: { test: { entity: 'note' } } } })
      throws(() => st.sdk('joplin'), /expects map, but found string/)
      st.close()
    }
    finally { resetFactories() }
  })
})
