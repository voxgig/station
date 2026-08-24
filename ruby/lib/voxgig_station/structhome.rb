# frozen_string_literal: true

# Locate the sibling voxgig/struct checkout whose Ruby port backs
# validate_config (design station.md 4).
#
# struct is not published as a gem yet, so this port finds it on disk -
# by $STRUCT_HOME, or by looking where a checkout usually sits. (The same
# convention test/helper.rb uses for voxgig/omni, and sekreto follows.)
# Unlike omni this is a RUNTIME dependency: validate_config runs at
# open(), not only under test.
#
# A port of javascript/src/structhome.js; typescript/src/shape.ts is
# canonical for what it is used for.

module VoxgigStation
  # The struct Ruby port's gemspec puts its require path at the checkout's
  # `ruby/` directory, so the file itself is the marker.
  STRUCT_MARKER = 'ruby/voxgig_struct.rb'

  module_function

  def structhome(marker = nil)
    marker ||= STRUCT_MARKER
    here = File.dirname(File.expand_path(__FILE__))
    candidates = [
      ENV.fetch('STRUCT_HOME', nil),
      File.join(here, '..', '..', '..', '..', 'struct'),
      File.join(here, '..', '..', '..', '..', '..', 'struct'),
      '/workspace/struct',
      '/home/user/struct',
    ]

    candidates.each do |cand|
      return File.expand_path(cand) if cand && File.exist?(File.join(cand, marker))
    end

    raise 'station: voxgig/struct not found - set STRUCT_HOME'
  end

  # The struct Ruby port itself: an installed gem when there is one, else
  # the sibling checkout - the same order the suites use for sekreto.
  #
  # Resolved on FIRST USE rather than at require time: `require
  # 'voxgig_station'` must not fail on a missing checkout for a caller
  # that never validates a config.
  def structmod
    return VoxgigStruct if defined?(VoxgigStruct)

    begin
      require 'voxgig_struct'
    rescue LoadError
      path = File.join(structhome, 'ruby')
      $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
      require 'voxgig_struct'
    end

    VoxgigStruct
  end
end
