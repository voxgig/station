// A port of typescript/src/profile.ts, which is canonical.

const Fs = require('node:fs')
const Os = require('node:os')
const Path = require('node:path')

const { validname } = require('@voxgig/sekreto-js')

const { StationError } = require('./error')

// station.json lookup: cwd upward to the repo root, then
// ~/.voxgig/station.json (design §3.5). A repo root is where .git lives;
// with no repo the walk stops at the filesystem root.
function findConfigFile(from) {
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

function loadConfig(from) {
  const file = findConfigFile(from)
  if (null == file) { return null }
  const text = Fs.readFileSync(file, 'utf8')
  return JSON.parse(text)
}

// Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
// else 'default' (design §3.5 - env vars rank above station.json but
// below open() opts; profile NAME selection follows the same order with
// open() opts winning).
function selectProfile(optProfile) {
  if (null != optProfile && '' !== optProfile) { return optProfile }
  const env = process.env.VOXGIG_STATION_PROFILE
  if (null != env && '' !== env) { return env }
  return 'default'
}

// Merge the base profile ('default') with the selected overlay:
// deep-merge per plugin, EXCEPT secrets.providers which replaces
// wholesale (design §3.5, §5.2 - chain order decides which store wins,
// so a positional merge would be actively dangerous). The `profile`
// corpus section pins this.
function resolveProfile(config, profileName) {
  const profiles = (config && config.profiles) || {}
  const base = profiles['default'] || {}
  const overlay = 'default' === profileName ? {} : (profiles[profileName] || {})

  const providers = overlay.secrets?.providers ?? base.secrets?.providers ??
    [{ kind: 'env' }]

  const plugin = {}
  for (const src of [base.plugin || {}, overlay.plugin || {}]) {
    for (const slug of Object.keys(src)) {
      plugin[slug] = { ...(plugin[slug] || {}), ...src[slug] }
    }
  }

  // A configured secret name sekreto would reject is caught at profile
  // load, not first request (design §14 station_secret_name).
  for (const slug of Object.keys(plugin)) {
    const name = plugin[slug].secret
    if (null != name && !validname(name)) {
      throw new StationError('station_secret_name',
        'profile "' + profileName + '" plugin "' + slug +
        '": secret name rejected by sekreto: ' + JSON.stringify(name))
    }
  }

  return { name: profileName, providers, plugin }
}

module.exports = {
  findConfigFile,
  loadConfig,
  resolveProfile,
  selectProfile,
}
