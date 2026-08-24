/* The FILE half of profile handling - finding and reading
 * station.json - and the scope rule that hangs off where it was found.
 * NODE-ONLY by construction (fs/os/path), which is the §2.2 / §17
 * Phase 1 split: the browser entry never imports this module, and
 * `Station` reaches it through the ConfigFileIO seam the node entry
 * registers. The pure half (selectProfile, refapi, resolveProfile)
 * lives in `profilecore.ts` and is re-exported here so every existing
 * import of `./profile` keeps working. */

import Fs from 'node:fs'
import Os from 'node:os'
import Path from 'node:path'

import { StationError } from './error'
import { StationConfig } from './types'

export {
  refapi, resolveProfile, selectProfile,
} from './profilecore'
export type { ResolvedProfile } from './profilecore'

// station.json lookup: cwd upward to the repo root, then
// ~/.voxgig/station.json (design §3.5). A repo root is where .git lives;
// with no repo the walk stops at the filesystem root.
export function findConfigFile(from?: string): string | null {
  let dir = Path.resolve(from || process.cwd())
  for (; ;) {
    const candidate = Path.join(dir, 'station.json')
    if (Fs.existsSync(candidate)) { return candidate }
    const atRepoRoot = Fs.existsSync(Path.join(dir, '.git'))
    const parent = Path.dirname(dir)
    if (atRepoRoot || parent === dir) { break }
    dir = parent
  }
  const home = Path.join(Os.homedir(), '.voxgig', 'station.json')
  return Fs.existsSync(home) ? home : null
}

export function loadConfig(from?: string): StationConfig | null {
  const file = findConfigFile(from)
  if (null == file) { return null }
  const text = Fs.readFileSync(file, 'utf8')
  // A file that is not JSON is a config error, not a raw SyntaxError
  // escaping open(): the reader found station.json and could not use
  // it, which is exactly what station_config_invalid exists to say.
  try {
    return JSON.parse(text)
  }
  catch (err: any) {
    throw new StationError('station_config_invalid',
      'station.json at ' + file + ' is not valid JSON: ' + err.message)
  }
}

// Which side of the review boundary the config came from (§6.3).
//
// `package` and `export` are honoured only from REPO-SCOPED config,
// because a user-level file is outside the repo's review boundary and a
// `package` key arriving from it names code to import. Everything else
// in a user-level config still applies - this narrows one key rather
// than distrusting the file.
export function configScope(from?: string): 'repo' | 'user' | 'none' {
  const file = findConfigFile(from)
  if (null == file) { return 'none' }
  const home = Path.join(Os.homedir(), '.voxgig', 'station.json')
  return file === home ? 'user' : 'repo'
}
