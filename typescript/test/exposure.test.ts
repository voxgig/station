import { describe, test, beforeEach, afterEach } from 'node:test'
import { equal, ok } from 'node:assert'
import { inspect } from 'node:util'

import { Station } from '../src/Station'

const SECRET = 'exposure-key-101'

// An SDK generated without the station feature, reduced to what the
// carried adapter touches: the options kept as given, extend features
// initialised in order, and a transport that answers 200.
function fakeSDK() {
  const config = {
    main: { slug: 'taskpad', name: 'taskpad', version: '1.0.0' },
    options: { auth: { prefix: '' }, server: {} },
    entity: {},
  }
  class SDK {
    _mode = 'live'
    _features: any[] = []
    _options: any
    _ctx: any

    constructor(options: any) {
      this._options = options
      this._ctx = {
        client: this,
        utility: { fetcher: async () => ({ status: 200, headers: { get: () => null } }) },
        options,
        config,
      }
      for (const f of options.extend || []) {
        this._features.push(f)
        f.init(this._ctx, options.feature?.[f.name] || {})
      }
    }

    options() { return this._options }

    async call() {
      return this._ctx.utility.fetcher({ client: this }, 'http://api.test/todo', {
        method: 'GET', headers: { authorization: this._options.apikey },
      })
    }
  }
  return SDK
}

function shows(value: any): string {
  return JSON.stringify(value) + inspect(value, { depth: Infinity, showHidden: true })
}

function reachesStation(value: any, seen = new Set<any>()): boolean {
  if (value instanceof Station) { return true }
  if (null == value || 'object' !== typeof value || seen.has(value)) { return false }
  seen.add(value)
  return Object.keys(value).some((k) => reachesStation(value[k], seen))
}

describe('exposure', () => {
  beforeEach(() => {
    Station.reset()
    process.env.TASKPAD_APIKEY = SECRET
  })
  afterEach(() => {
    Station.reset()
    delete process.env.TASKPAD_APIKEY
  })

  test('a bound client\'s options hold no secret after a live request', async () => {
    const station = Station.open({ config: null })
    const client = station.connect(fakeSDK())
    await client.call()

    ok(!shows(client.options()).includes(SECRET))
    ok(!shows(station).includes(SECRET))
    ok(!reachesStation(client.options()), 'the options reach no Station')
    equal('function', typeof client.options().feature.station.station)
    station.close()
  })

  test('the caller\'s own key does not ride the activation entry', async () => {
    delete process.env.TASKPAD_APIKEY
    const station = Station.open({ config: null })
    const client = station.adopt(fakeSDK(), { apikey: SECRET })
    await client.call()

    ok(!shows(client.options()).includes(SECRET))
    ok(!shows(station).includes(SECRET))
    station.close()
  })

  test('inverted binding: the activation entry holds neither', () => {
    const station = Station.open({ config: null })
    const options = station.options({ apikey: SECRET })

    equal(SECRET, options.apikey, 'the SDK still gets the key it is given')
    ok(!shows(options.feature.station).includes(SECRET))
    ok(!reachesStation(options), 'the options reach no Station')
    station.close()
  })
})
