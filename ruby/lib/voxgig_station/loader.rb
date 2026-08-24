# frozen_string_literal: true

# The loader (design station.md 6.3), where the language allows it.
#
# In ts, js, py, RB, php, perl, lua, elixir and clojure a module can be
# imported by name at runtime, so `api.<slug>.package` closes the loop:
# station requires the package (which triggers self-registration, 6.2
# path 1) and then looks up the factory.
#
# rb-specific, and it is one accommodation rather than a divergence:
#
#  - THERE IS ONE MODULE SYSTEM. `require` is synchronous and so is
#    `sdk()`, so the ts/js CommonJS-vs-ESM split - `loadAsync` and the
#    `await station.load()` preload it exists for - has no counterpart
#    here. `Station#load` is kept as a SYNCHRONOUS preload of the
#    declared packages; nothing needs it before `sdk()`.
#  - `require` returns true/false, not a module object, so the "module"
#    a factory is read off is a NAMESPACE - `Object` for a package whose
#    generated class is top-level, which is what sdkgen's rb target
#    emits. `export` names a CONSTANT in it.
#
# THIS IS A CODE-LOADING SURFACE DRIVEN BY A CONFIG FILE, so it has
# rules, and they are enforced here rather than documented and hoped
# for. See check_package and Station#loader_package.
#
# A port of typescript/src/loader.ts, which is canonical.

require 'json'

require_relative 'error'
require_relative 'factory'

module VoxgigStation
  # The fixed alias every generated package exports.
  #
  # `export` defaults to this rather than to a derived class name because
  # it is the same identifier in every generated package, where
  # `camelify(slug) + 'SDK'` is a rule that has to be recomputed and can
  # be wrong. The derived name is the SECOND attempt and an explicit
  # `export` the third. `package` has NO default: a guessed package name
  # that resolves to the wrong thing is worse than a required key.
  DEFAULT_EXPORT = 'SDK'

  module_function

  # `stripe-eu` -> `StripeEu`, for the second-attempt export name.
  def camelify(slug)
    slug.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?)
      .map { |s| s[0].upcase + s[1..].to_s }.join
  end

  # Only MODULE NAMES, resolved by the host language's ordinary
  # resolution from the application root. Never a filesystem path, never
  # a URL, never anything relative - a config file naming a path is a
  # config file reaching outside the dependency graph it is allowed to
  # name.
  def check_package(api, pkg)
    p = pkg.to_s

    # A TRAVERSAL SEGMENT IS NOT A LEADING MARKER, and checking only the
    # first character misses it: `pkg/../../escape` starts with neither
    # `.` nor `/`, so a first-character check passes it and the host
    # resolves it from outside the named dependency. The whole point of
    # this function is that a configured package stays inside the
    # dependency graph a reviewer can see.
    seg = p.split('/', -1).any? { |x| '.' == x || '..' == x }
    bad = '' == p ||
      p.start_with?('.') ||
      p.start_with?('/') ||
      p.start_with?('~') ||
      seg ||
      p.include?('://') ||
      p.include?('\\')

    if bad
      raise StationError.new('station_sdk_load',
        'api "' + api.to_s + '": `package` must be a module name resolved ' \
        'from the application root, not a path or URL: ' + JSON.generate(pkg))
    end

    p
  end

  # Build a `{construct, config}` pair from a module that self-registered
  # nothing - the retrofit path for a package whose SDK predates the
  # station feature. It is NOT descriptor-blind: a generated main module
  # exports its constructor AND the `config` singleton beside it.
  def factory_from_module(api, mod, export_name = nil)
    mod = Object if mod.nil?
    tried = []

    pick = lambda do |n|
      tried << n.to_s
      const_lookup(mod, n)
    end

    ctor = nil
    ctor = pick.call(export_name) if !export_name.nil? && '' != export_name
    ctor = pick.call(DEFAULT_EXPORT) if ctor.nil?
    ctor = pick.call(camelify(api) + 'SDK') if ctor.nil?

    unless ctor.respond_to?(:new)
      raise StationError.new('station_sdk_load',
        'api "' + api.to_s + '": no SDK constructor found on the module; ' \
        'tried [' + tried.join(', ') + ']. Set `export` to the exported name.')
    end

    config = module_config(mod)
    config = module_config(ctor) if config.nil?
    if config.nil?
      raise StationError.new('station_sdk_load',
        'api "' + api.to_s + '": the module exports a constructor but no ' \
        '`config` singleton, so its feature schema and transport roles ' \
        'cannot be read before construction (6.2)')
    end

    { construct: ->(options) { ctor.new(options) }, config: config }
  end

  # `config`, then `CONFIG` - the method spelling first, because a
  # generated rb package exposes its embedded config as a module method
  # and a hand-written one usually as a constant. Looked for on the
  # namespace and then on the constructor itself, which in rb IS a
  # namespace: `Taskpad_sdk::CONFIG` sits beside the class as often as
  # under it.
  def module_config(holder)
    return nil if holder.nil?
    return holder.config if holder.respond_to?(:config)

    return nil unless holder.is_a?(Module)

    const_lookup(holder, 'CONFIG')
  end

  # A constant on a namespace, or nil - never a NameError for a spelling
  # that is not a constant name at all (`export: "sdk"`).
  def const_lookup(mod, name)
    return nil unless mod.is_a?(Module)

    mod.const_defined?(name.to_s, false) ? mod.const_get(name.to_s, false) : nil
  rescue NameError
    nil
  end

  # Require the package. Returns true when the api has a factory
  # afterwards - either because requiring the package triggered
  # self-registration, or because one was built from its exports.
  def load_sync(api, pkg, export_name = nil)
    check_package(api, pkg)
    return true unless factory_for(api).nil?

    begin
      require pkg.to_s
    rescue StationError
      # A package that self-registers a CONFLICTING factory is its own
      # error, told in its own words.
      raise
    rescue StandardError, LoadError => e
      raise StationError.new('station_sdk_load',
        'api "' + api.to_s + '": package "' + pkg.to_s + '" could not be ' \
        'imported: ' + e.message.to_s)
    end

    # Path 1: the package self-registered while being required.
    return true unless factory_for(api).nil?

    provide(api, factory_from_module(api, Object, export_name))
    true
  end
end
