import { describe, test } from 'node:test'
import { deepStrictEqual } from 'node:assert'

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
})
