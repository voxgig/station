const { test } = require('node:test')
const { deepStrictEqual } = require('node:assert')
const Fs = require('node:fs')
const Path = require('node:path')

const { CONFIG_SHAPE } = require('../src/config-shape')

// The published package carries no `spec/`, so the shipped copy is what
// validateConfig reads.
test('config-shape mirror matches the spec file', () => {
  const onDisk = JSON.parse(Fs.readFileSync(
    Path.join(__dirname, '..', '..', 'spec', 'config-shape.json'), 'utf8'))
  deepStrictEqual(CONFIG_SHAPE, onDisk,
    'src/config-shape.js has drifted from spec/config-shape.json - ' +
    'edit the JSON and re-run `make sync-shape`')
})
