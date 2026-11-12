const { test } = require('node:test')
const Assert = require('node:assert')
const Fs = require('node:fs')
const Os = require('node:os')
const Path = require('node:path')

const { loadConfig } = require('../src/profile')

function tmpdir() {
  return Fs.mkdtempSync(Path.join(Os.tmpdir(), 'station-config-'))
}

test('malformed station.json raises station_config_invalid', () => {
  const dir = tmpdir()
  const file = Path.join(dir, 'station.json')
  Fs.writeFileSync(file, '{ "station": 1, ')
  try {
    Assert.throws(() => loadConfig(dir), (err) => {
      Assert.equal(err.code, 'station_config_invalid')
      Assert.ok(-1 !== err.message.indexOf(file),
        'the error names the file it could not read: ' + err.message)
      return true
    })
  }
  finally {
    Fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('an unpaired surrogate escape raises station_config_invalid', () => {
  const dir = tmpdir()
  const file = Path.join(dir, 'station.json')
  Fs.writeFileSync(file, '{ "station": 1, "profiles": { "x\\ud800": {} } }')
  try {
    Assert.throws(() => loadConfig(dir), (err) => {
      Assert.equal(err.code, 'station_config_invalid')
      Assert.equal(err.message, 'station_config_invalid: station.json at ' +
        file + ' has an unpaired surrogate escape in "x\\ud800"')
      return true
    })
  }
  finally {
    Fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('well-formed station.json still loads', () => {
  const dir = tmpdir()
  try {
    Fs.writeFileSync(Path.join(dir, 'station.json'), '{ "station": 1 }')
    Assert.equal(loadConfig(dir).station, 1)
  }
  finally {
    Fs.rmSync(dir, { recursive: true, force: true })
  }
})
