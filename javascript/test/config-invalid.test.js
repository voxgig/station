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

// The corpus is JSON text, so it cannot carry these bytes; each port pins them.
test('station.json is read as UTF-8, and refused when it is not', () => {
  const dir = tmpdir()
  const file = Path.join(dir, 'station.json')
  const doc = (note) => Buffer.concat([
    Buffer.from('{ "station": 1, "profiles": { "default": { "sdk": { "joplin": { "options": { "note": "'),
    note, Buffer.from('" } } } } } }')])
  try {
    Fs.writeFileSync(file, doc(Buffer.from('\u00e9\u{1F600}', 'utf8')))
    const note = loadConfig(dir).profiles.default.sdk.joplin.options.note
    Assert.deepEqual([...note], ['\u00e9', '\u{1F600}'], 'raw UTF-8 reads as its characters')

    const notUtf8 = {
      stray: [0xe9], overlong: [0xc0, 0xaf], surrogate: [0xed, 0xa0, 0x80],
      outofrange: [0xf4, 0x90, 0x80, 0x80], truncated: [0xf0, 0x9f, 0x98],
    }
    for (const [shape, bytes] of Object.entries(notUtf8)) {
      Fs.writeFileSync(file, doc(Buffer.from(bytes)))
      Assert.throws(() => loadConfig(dir), (err) => {
        Assert.equal(err.code, 'station_config_invalid')
        Assert.equal(err.message,
          'station_config_invalid: station.json at ' + file + ' is not UTF-8')
        return true
      }, shape)
    }

    Fs.writeFileSync(file, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), doc(Buffer.from('ok'))]))
    Assert.throws(() => loadConfig(dir), (err) => {
      Assert.equal(err.code, 'station_config_invalid')
      Assert.ok(err.message.includes(' is not valid JSON: '), err.message)
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
