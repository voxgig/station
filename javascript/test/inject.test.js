// A port of typescript/test/inject.test.ts, which is canonical.

const { describe, test, beforeEach, afterEach } = require('node:test')
const { deepStrictEqual, equal, notEqual, ok, rejects } = require('node:assert')
const { inspect } = require('node:util')

const { Station } = require('../src/Station')
const { featureBinding } = require('../src/adapter')
const { SecretBroker } = require('../src/secrets')

const VALUE = 'tok!en 1'
const SENT = 'tok%21en%201'

// A live client whose credential goes in the query, the way an SDK
// generated from an `in: query` security scheme places it.
function liveClient(slug, inner) {
  const client = { _features: [{ name: 'station' }], _mode: 'live' }
  const ctx = {
    client,
    utility: { fetcher: inner },
    options: { feature: {} },
    config: {
      main: { slug, name: slug, version: '1.0.0' },
      options: { auth: { prefix: '' }, server: {} },
      entity: {},
    },
  }
  return { client, ctx }
}

function placedUrl(ctx) {
  return 'http://127.0.0.1:41184/notes?fields=id%2Ctitle&token=' +
    encodeURIComponent(ctx.options.apikey)
}

describe('inject', () => {
  beforeEach(() => { process.env.JOPLIN_APIKEY = VALUE })
  afterEach(() => { delete process.env.JOPLIN_APIKEY })

  test('a query-placed credential reaches the wire, and nothing else', async () => {
    const seen = []
    const { client, ctx } = liveClient('joplin', async (_f, url, def) => {
      seen.push({ url, def })
      return { status: 200, headers: { get: () => null } }
    })
    const st = new Station({ config: null })
    featureBinding(ctx, { station: st })

    const url = placedUrl(ctx)
    const fetchdef = { url, method: 'GET', headers: {} }
    await ctx.utility.fetcher({ client }, url, fetchdef)

    equal(seen.length, 1)
    equal(seen[0].url, 'http://127.0.0.1:41184/notes?fields=id%2Ctitle&token=' + SENT)
    equal(seen[0].def.url, seen[0].url)
    equal(fetchdef.url, url, 'the SDK\'s fetchdef keeps the placeholder')
    ok(!JSON.stringify(st.events()).includes(SENT))
    ok(!JSON.stringify(st.events()).includes(VALUE))
    st.close()
  })

  test('a transport error quoting the URL is scrubbed', async () => {
    const { client, ctx } = liveClient('joplin',
      async (_f, url) => { throw new Error('failed: GET ' + url) })
    const st = new Station({ config: null })
    featureBinding(ctx, { station: st })

    const url = placedUrl(ctx)
    await rejects(ctx.utility.fetcher({ client }, url, { url, method: 'GET', headers: {} }),
      (err) => {
        ok(!err.message.includes(SENT), err.message)
        ok(err.message.includes('[redacted]'), err.message)
        return true
      })
    ok(!JSON.stringify(st.events()).includes(SENT))
    st.close()
  })

  // The request URL carries no placeholder; only the fetchdef's own url does.
  async function failOnDefUrl(fail) {
    const { client, ctx } = liveClient('joplin',
      async (_f, _url, def) => fail(new Error('failed: GET ' + def.url)))
    const st = new Station({ config: null })
    featureBinding(ctx, { station: st })
    try {
      const fetchdef = { url: placedUrl(ctx), method: 'GET', headers: {} }
      return await ctx.utility.fetcher({ client }, 'http://127.0.0.1:41184/notes', fetchdef)
        .catch((err) => err)
    }
    finally { st.close() }
  }

  test('a thrown error quoting only the fetchdef url is scrubbed', async () => {
    const err = await failOnDefUrl((err) => { throw err })
    ok(err instanceof Error)
    ok(!err.message.includes(SENT), err.message)
    ok(err.message.includes('[redacted]'), err.message)
  })

  test('a returned error quoting only the fetchdef url is scrubbed', async () => {
    const err = await failOnDefUrl((err) => err)
    ok(err instanceof Error)
    ok(!err.message.includes(SENT), err.message)
    ok(err.message.includes('[redacted]'), err.message)
  })

  // fetch's own failure: the message quotes the URL, and so do the
  // cause's `input` and the head's stack.
  test('a transport error\'s cause chain is scrubbed', async () => {
    const { client, ctx } = liveClient('joplin', async (_f, url) => fetch(url))
    const st = new Station({ config: null })
    featureBinding(ctx, { station: st })

    const url = 'http://bad host/notes?token=' + encodeURIComponent(ctx.options.apikey)
    await rejects(ctx.utility.fetcher({ client }, url, { url, method: 'GET', headers: {} }),
      (err) => {
        equal(err.cause?.code, 'ERR_INVALID_URL', 'the cause is kept')
        ok(err.cause.input.includes('[redacted]'), err.cause.input)
        const shown = inspect(err, { depth: null })
        ok(!shown.includes(SENT) && !shown.includes(VALUE), shown)
        return true
      })
    ok(!JSON.stringify(st.events()).includes(SENT))
    st.close()
  })

  async function failWith(make) {
    const { client, ctx } = liveClient('joplin', async (_f, url) => { throw make(url) })
    const st = new Station({ config: null })
    featureBinding(ctx, { station: st })
    try {
      const url = placedUrl(ctx)
      return await ctx.utility.fetcher({ client }, url, { url, method: 'GET', headers: {} })
        .catch((err) => err)
    }
    finally { st.close() }
  }

  test('a cause that cannot be scrubbed is cut off', async () => {
    let thrown = null
    const err = await failWith((url) => thrown = new Error('fetch failed',
      { cause: Object.freeze(new Error('GET ' + url)) }))
    equal(err, thrown)
    equal(err.cause, undefined)
  })

  test('an error that cannot be scrubbed comes back as an equivalent', async () => {
    let thrown = null
    const err = await failWith((url) =>
      thrown = Object.freeze(Object.assign(new Error('GET ' + url), { code: 'E_GET' })))
    notEqual(err, thrown)
    equal(err.code, 'E_GET')
    ok(err.message.includes('[redacted]'), err.message)
    ok(!inspect(err, { depth: null }).includes(SENT))
  })

  test('a thrown string is scrubbed', async () => {
    const err = await failWith((url) => 'GET ' + url)
    ok('string' === typeof err && err.includes('[redacted]') && !err.includes(SENT), err)
  })

  test('connect keeps as and instance out of the SDK\'s own options', () => {
    let built = null
    class ClosedSDK {
      constructor(options) { built = options }
    }
    const st = new Station({ config: null })
    st.connect(ClosedSDK, { as: 'spare', base: 'http://x' })
    deepStrictEqual(Object.keys(built).sort(), ['base', 'extend', 'feature'])
    equal(built.feature.station.as, 'spare')

    st.connect(ClosedSDK, { instance: 'joplin$spare' })
    deepStrictEqual(Object.keys(built).sort(), ['extend', 'feature'])
    equal(built.feature.station.instance, 'joplin$spare')
    st.close()
  })
})

describe('scrub', () => {
  test('a held value inside another held value\'s encoded form', () => {
    for (const held of [['%', 'secret!'], ['secret!', '%']]) {
      const broker = new SecretBroker([])
      held.forEach((value, i) => broker.hoist('k' + i, value))
      equal(broker.scrub('token=secret%21'), 'token=[redacted]', held.join(' '))
    }
  })

  test('forms that overlap in the text are redacted as one span', () => {
    const broker = new SecretBroker([])
    broker.hoist('a', 'ab!')
    broker.hoist('b', '!c')
    equal(broker.scrub('x=ab%21c&y=!c'), 'x=[redacted]&y=[redacted]')
  })

  test('sekreto\'s own redact cannot hide an encoded form', async () => {
    process.env.SCRUB_APIKEY = 'abcd'
    try {
      const broker = new SecretBroker([{ kind: 'env' }])
      equal(await broker.value('scrub', 'scrub.apikey'), 'abcd')
      broker.hoist('other', 'abcd!x')
      equal(broker.scrub('k=abcd%21x'), 'k=[redacted]')
    }
    finally { delete process.env.SCRUB_APIKEY }
  })
})
