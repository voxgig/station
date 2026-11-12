
import { test } from 'node:test'
import * as Assert from 'node:assert'
import * as Fs from 'node:fs'
import * as Os from 'node:os'
import * as Path from 'node:path'

import { loadConfig } from '../src/profile'

function tmpdir(): string {
  return Fs.mkdtempSync(Path.join(Os.tmpdir(), 'station-config-'))
}

test('malformed station.json raises station_config_invalid', () => {
  const dir = tmpdir()
  const file = Path.join(dir, 'station.json')
  Fs.writeFileSync(file, '{ "station": 1, ')
  try {
    Assert.throws(() => loadConfig(dir), (err: any) => {
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
    Assert.throws(() => loadConfig(dir), (err: any) => {
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
    const config = loadConfig(dir)
    Assert.equal((config as any).station, 1)
  }
  finally {
    Fs.rmSync(dir, { recursive: true, force: true })
  }
})
