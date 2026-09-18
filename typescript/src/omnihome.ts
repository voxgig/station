
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'

export function omnihome(marker = 'spec/fib.json'): string {
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
export function specfile(): string {
  return resolve(join(__dirname, '..', '..', '..', 'spec', 'station.json'))
}
