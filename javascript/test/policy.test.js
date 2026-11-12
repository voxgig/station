// A port of the policy-hostname and policy-mode halves of
// typescript/test/policy.test.ts, which is canonical.

const { describe, test } = require('node:test')
const { equal, match, ok } = require('node:assert')

const { Station } = require('../src/Station')
const { featureBinding } = require('../src/adapter')

function fakeClient(slug) {
  const client = { _features: [{ name: 'station' }], _mode: 'live' }
  const ctx = {
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

function policyStation(slug, policy) {
  return new Station({
    config: { station: 1, profiles: { default: { sdk: { [slug]: { policy } } } } },
  })
}

describe('policy-hostname', () => {

  // URL.hostname: an IPv6 host keeps its brackets, and neither a port nor
  // the userinfo, a raw `@` in its password among it, reaches the host.
  test('the hosts policy compares the hostname URL.hostname reads', async () => {
    const cases = [
      ['[::1]', 'http://[::1]:8080/x', true],
      ['[::1]', 'http://[::2]:8080/x', false],
      ['api.test', 'https://api.test:443/x', true],
      ['api.test', 'https://evil.test:443/x', false],
      ['api.test', 'https://u:p@ss@api.test/x', true],
      ['api.test', 'https://api.test:x@evil.test/x', false],
      ['api.test', 'https://API.TEST/x', true],
      ['api.test', 'https://EVIL.TEST/x', false],
    ]
    for (const [host, url, allowed] of cases) {
      const st = policyStation('solar', { hosts: [host] })
      const { ctx } = fakeClient('solar')
      featureBinding(ctx, { station: st })
      const out = await ctx.utility.fetcher({ client: ctx.client }, url, { headers: {} })
      equal(allowed ? 200 : 'station_host_allow', allowed ? out.status : out.code,
        host + ' against ' + url)
      st.close()
    }
  })
})

async function liveRequest(st, slug, mode) {
  const { ctx } = fakeClient(slug)
  ctx.client._mode = mode || 'live'
  featureBinding(ctx, { station: st })
  return ctx.utility.fetcher({ client: ctx.client }, 'https://api.x.com/v1',
    { headers: {} })
}

describe('policy-mode', () => {

  test('mode "block" refuses a live operation with its own code', async () => {
    const st = policyStation('solar', { mode: 'block' })
    const out = await liveRequest(st, 'solar')

    ok(out instanceof Error)
    equal('station_blocked', out.code)
    match(String(out.message), /mode "block"/)

    const errs = st.events().filter((e) => 'error' === e.kind)
    equal(1, errs.length)
    equal('station_blocked', errs[0].err.code)
    st.close()
  })

  test('mode "block" wins over a hosts policy that admits the host', async () => {
    const st = policyStation('solar', { mode: 'block', hosts: ['api.x.com'] })
    const out = await liveRequest(st, 'solar')
    equal('station_blocked', out.code)
    st.close()
  })

  test('proxy-era modes are accepted grammar that fails station_no_proxy', async () => {
    for (const mode of ['record', 'replay', 'mock']) {
      const st = policyStation('solar', { mode })
      const out = await liveRequest(st, 'solar')
      ok(out instanceof Error, mode + ' must refuse')
      equal('station_no_proxy', out.code)
      st.close()
    }
  })

  test('mode "live" and an absent mode both pass traffic', async () => {
    for (const policy of [{ mode: 'live' }, {}]) {
      const st = policyStation('solar', policy)
      const out = await liveRequest(st, 'solar')
      equal(200, out.status)
      st.close()
    }
  })

  test('mode gates LIVE traffic only, like hosts', async () => {
    const st = policyStation('solar', { mode: 'block' })
    const out = await liveRequest(st, 'solar', 'test')
    equal(200, out.status)
    st.close()
  })
})
