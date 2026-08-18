// Locate the sibling voxgig/omni checkout that drives the shared spec.
//
// station's conformance tests are omni tests: the same spec/station.json
// runs in every port. omni is not published yet, so the tests find it on
// disk - by $OMNI_HOME, or by looking where a checkout usually sits.
// (The same convention sekreto uses.)
//
// A port of typescript/src/omnihome.ts, which is canonical - the
// candidate depths differ by one because this port runs straight from
// src, with no dist layer.

const { existsSync } = require('node:fs')
const { join, resolve } = require('node:path')

function omnihome(marker) {
  marker = null == marker ? 'spec/fib.json' : marker
  const candidates = [
    process.env.OMNI_HOME,
    join(__dirname, '..', '..', '..', 'omni'),
    join(__dirname, '..', '..', '..', '..', 'omni'),
    '/workspace/omni',
    '/home/user/omni',
  ]

  for (const candidate of candidates) {
    if (candidate && existsSync(join(candidate, marker))) {
      return resolve(candidate)
    }
  }

  throw new Error('station: voxgig/omni not found - set OMNI_HOME')
}

// The station spec, wherever this port is running from.
function specfile() {
  return resolve(join(__dirname, '..', '..', 'spec', 'station.json'))
}

module.exports = {
  omnihome,
  specfile,
}
