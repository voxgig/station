// Locate the sibling voxgig/struct checkout whose javascript port backs
// validateConfig (design §4).
//
// struct is not published yet, so this port finds it on disk - by
// $STRUCT_HOME, or by looking where a checkout usually sits. (The same
// convention omnihome.js uses for voxgig/omni, and sekreto follows.)
// Unlike omni this is a RUNTIME dependency: validateConfig runs at
// open(), not just under test.

const { existsSync } = require('node:fs')
const { join, resolve } = require('node:path')

function structhome(marker) {
  marker = null == marker ? 'javascript/src/struct.js' : marker
  const candidates = [
    process.env.STRUCT_HOME,
    join(__dirname, '..', '..', '..', 'struct'),
    join(__dirname, '..', '..', '..', '..', 'struct'),
    '/workspace/struct',
    '/home/user/struct',
  ]

  for (const candidate of candidates) {
    if (candidate && existsSync(join(candidate, marker))) {
      return resolve(candidate)
    }
  }

  throw new Error('station: voxgig/struct not found - set STRUCT_HOME')
}

// The struct javascript port itself, required from the checkout.
function structmod() {
  return require(join(structhome(), 'javascript', 'src', 'struct.js'))
}

module.exports = {
  structhome,
  structmod,
}
