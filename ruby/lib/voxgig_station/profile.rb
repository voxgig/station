# frozen_string_literal: true

# station.json lookup and profile resolution (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical.

require 'json'

require 'voxgig_sekreto'

require_relative 'error'

module VoxgigStation
  module_function

  # station.json lookup: cwd upward to the repo root, then
  # ~/.voxgig/station.json (design station.md 3.5). A repo root is where
  # .git lives; with no repo the walk stops at the filesystem root.
  def find_config_file(from = nil)
    dir = File.expand_path(from || Dir.pwd)
    loop do
      candidate = File.join(dir, 'station.json')
      return candidate if File.exist?(candidate)

      at_repo_root = File.exist?(File.join(dir, '.git'))
      parent = File.dirname(dir)
      break if at_repo_root || parent == dir

      dir = parent
    end
    home = File.join(Dir.home, '.voxgig', 'station.json')
    File.exist?(home) ? home : nil
  end

  def load_config(from = nil)
    file = find_config_file(from)
    return nil if file.nil?

    JSON.parse(File.read(file))
  end

  # Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
  # else 'default' (design station.md 3.5 - env vars rank above
  # station.json but below open() opts; profile NAME selection follows
  # the same order with open() opts winning).
  def select_profile(opt_profile = nil)
    return opt_profile if !opt_profile.nil? && '' != opt_profile

    env = ENV.fetch('VOXGIG_STATION_PROFILE', nil)
    return env if !env.nil? && '' != env

    'default'
  end

  # Merge the base profile ('default') with the selected overlay:
  # deep-merge per plugin, EXCEPT secrets.providers which replaces
  # wholesale (design station.md 3.5, 5.2 - chain order decides which
  # store wins, so a positional merge would be actively dangerous). The
  # `profile` corpus section pins this.
  def resolve_profile(config, profile_name)
    profiles = config.is_a?(Hash) && config['profiles'].is_a?(Hash) ? config['profiles'] : {}
    base = profiles['default'].is_a?(Hash) ? profiles['default'] : {}
    overlay = 'default' == profile_name ? {} : (profiles[profile_name].is_a?(Hash) ? profiles[profile_name] : {})

    providers = providers_of(overlay) || providers_of(base) || [{ 'kind' => 'env' }]

    plugin = {}
    [base['plugin'], overlay['plugin']].each do |src|
      next unless src.is_a?(Hash)

      src.each do |slug, p|
        next unless p.is_a?(Hash)

        plugin[slug] = (plugin[slug] || {}).merge(p)
      end
    end

    # A configured secret name sekreto would reject is caught at profile
    # load, not first request (design station.md 14 station_secret_name).
    plugin.each do |slug, p|
      name = p['secret']
      next if name.nil?
      next if VoxgigSekreto.validname(name)

      raise StationError.new('station_secret_name',
        'profile "' + profile_name + '" plugin "' + slug +
        '": secret name rejected by sekreto: ' + name.inspect)
    end

    { 'name' => profile_name, 'providers' => providers, 'plugin' => plugin }
  end

  def providers_of(profile)
    secrets = profile.is_a?(Hash) ? profile['secrets'] : nil
    return nil unless secrets.is_a?(Hash)

    p = secrets['providers']
    p.is_a?(Array) ? p : nil
  end
end
