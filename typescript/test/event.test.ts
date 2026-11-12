import { describe, test } from 'node:test'
import { deepStrictEqual, equal } from 'node:assert'

import { Station } from '../src/Station'
import { featureBinding } from '../src/adapter'

function fakeClient(slug: string) {
  const client: any = { _features: [{ name: 'station' }], _mode: 'test' }
  const ctx: any = {
    client,
    utility: { fetcher: async () => ({ status: 200 }) },
    options: { feature: {} },
    config: {
      main: { slug, name: slug, version: '1.0.0' },
      options: { server: {} },
      entity: {},
    },
  }
  return { client, ctx }
}

describe('http-event', () => {

  test('the path is the request s own, escapes kept', async () => {
    const cases: [string, string, string][] = [
      ['https://h/vault/projects%2Flaunch%20plan.md', 'h',
        '/vault/projects%2Flaunch%20plan.md'],
      ['https://h', 'h', '/'],
      ['/vault/projects%2Flaunch%20plan.md?x=1', '',
        '/vault/projects%2Flaunch%20plan.md?x=1'],
    ]

    const st = new Station({ config: null })
    const { ctx } = fakeClient('vault')
    featureBinding(ctx, { station: st })

    for (const [url] of cases) {
      await ctx.utility.fetcher({ client: ctx.client }, url, { method: 'GET' })
    }

    const http = st.events().filter((e) => 'http' === e.kind)
    deepStrictEqual(http.map((e) => [e.http!.host, e.http!.path]),
      cases.map(([, host, path]) => [host, path]))

    st.close()
  })

  test('a URL that does not parse is reported whole, less its userinfo', async () => {
    const cases: [string, string, string][] = [
      ['https://u:s3cret@h x/y', '', 'https://h x/y'],
      ['https://u:p@h:99999/x', '', 'https://h:99999/x'],
      ['https://h x/y@z', '', 'https://h x/y@z'],
    ]

    const st = new Station({ config: null })
    const { ctx } = fakeClient('vault')
    featureBinding(ctx, { station: st })

    for (const [url] of cases) {
      await ctx.utility.fetcher({ client: ctx.client }, url, { method: 'GET' })
    }

    const http = st.events().filter((e) => 'http' === e.kind)
    deepStrictEqual(http.map((e) => [e.http!.host, e.http!.path]),
      cases.map(([, host, path]) => [host, path]))

    st.close()
  })

  test('the host reads as URL.host does', async () => {
    const cases: [string, string, string][] = [
      ['https://h:443/x', 'h', '/x'],
      ['http://h:80/x', 'h', '/x'],
      ['https://h:8443/x', 'h:8443', '/x'],
      ['https://u:p@h/x', 'h', '/x'],
      ['https://u:p@ss@h/x', 'h', '/x'],
      ['http://[::1]:8080/x', '[::1]:8080', '/x'],
      ['http://[::1]/x', '[::1]', '/x'],
      ['https://H/x', 'h', '/x'],
      ['https://h:/x', 'h', '/x'],
      ['https://h:0443/x', 'h', '/x'],
      ['https://h:08443/x', 'h:8443', '/x'],
    ]

    const st = new Station({ config: null })
    const { ctx } = fakeClient('vault')
    featureBinding(ctx, { station: st })

    for (const [url] of cases) {
      await ctx.utility.fetcher({ client: ctx.client }, url, { method: 'GET' })
    }

    const http = st.events().filter((e) => 'http' === e.kind)
    deepStrictEqual(http.map((e) => [e.http!.host, e.http!.path]),
      cases.map(([, host, path]) => [host, path]))

    st.close()
  })
})

describe('op-event', () => {

  // A failed operation reaches PreDone with its error result, and then
  // PreUnexpected as the pipeline throws it.
  test('one failed operation emits one op event', () => {
    const st = new Station({ config: null })
    const { ctx } = fakeClient('vault')
    const binding = featureBinding(ctx, { station: st })!

    const opctx: any = { op: { entity: 'note', name: 'load' }, result: { ok: false } }
    binding.PrePoint(opctx)
    binding.PreDone(opctx)
    binding.PreUnexpected(opctx)
    binding.PreUnexpected(opctx)

    const op = st.events().filter((e) => 'op' === e.kind)
    deepStrictEqual(op.map((e) => e.op!.outcome), ['err'])
    equal(op[0].corr, opctx.station$.corr)

    binding.PreUnexpected({ op: { entity: 'note', name: 'load' } })
    equal(1, st.events().filter((e) => 'op' === e.kind).length,
      'an operation station never opened emits nothing')

    st.close()
  })
})
