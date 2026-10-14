
import { describe, test, beforeEach, afterEach } from 'node:test'
import { deepStrictEqual, equal, ok, rejects } from 'node:assert'

import { Station } from '../src/Station'
import { featureBinding } from '../src/adapter'

const VALUE = 'tok!en 1'
const SENT = 'tok%21en%201'

// A live client whose credential goes in the query, the way an SDK
// generated from an `in: query` security scheme places it.
function liveClient(slug: string, inner: any) {
  const client: any = { _features: [{ name: 'station' }], _mode: 'live' }
  const ctx: any = {
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

function placedUrl(ctx: any): string {
  return 'http://127.0.0.1:41184/notes?fields=id%2Ctitle&token=' +
    encodeURIComponent(ctx.options.apikey)
}

describe('inject', () => {
  beforeEach(() => { process.env.JOPLIN_APIKEY = VALUE })
  afterEach(() => { delete process.env.JOPLIN_APIKEY })

  test('a query-placed credential reaches the wire, and nothing else', async () => {
    const seen: any[] = []
    const { client, ctx } = liveClient('joplin',
      async (_f: any, url: string, def: any) => {
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
      async (_f: any, url: string) => { throw new Error('failed: GET ' + url) })
    const st = new Station({ config: null })
    featureBinding(ctx, { station: st })

    const url = placedUrl(ctx)
    await rejects(ctx.utility.fetcher({ client }, url, { url, method: 'GET', headers: {} }),
      (err: Error) => {
        ok(!err.message.includes(SENT), err.message)
        ok(err.message.includes('[redacted]'), err.message)
        return true
      })
    ok(!JSON.stringify(st.events()).includes(SENT))
    st.close()
  })

  test('connect keeps as and instance out of the SDK\'s own options', () => {
    let built: any = null
    class ClosedSDK {
      constructor(options: any) { built = options }
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
