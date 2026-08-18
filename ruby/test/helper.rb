# frozen_string_literal: true

# Test wiring shared by the station-rb suites: put the sibling sekreto
# checkout on the load path (sekreto ships no gem yet; the require path
# is the resolution story), find the sibling voxgig/omni checkout, and
# find the shared spec.

HERE = File.dirname(File.expand_path(__FILE__))

def sibling(name, marker)
  cands = [
    ENV.fetch(name.upcase + '_HOME', nil),
    File.join(HERE, '..', '..', '..', name),
    File.join(HERE, '..', '..', '..', '..', name),
    '/workspace/' + name,
    '/home/user/' + name
  ]
  cands.each do |cand|
    return File.expand_path(cand) if cand && File.exist?(File.join(cand, marker))
  end
  raise 'station: voxgig/' + name + ' not found - set ' + name.upcase + '_HOME'
end

$LOAD_PATH.unshift(File.join(sibling('sekreto', 'ruby/lib/voxgig_sekreto.rb'), 'ruby', 'lib'))

# The library itself rides the load path too, so generated SDK code
# (whose station feature does a plain `require 'voxgig_station'`) resolves
# against THIS checkout when the integration suite loads one.
$LOAD_PATH.unshift(File.expand_path(File.join(HERE, '..', 'lib')))

require File.join(sibling('omni', 'spec/fib.json'), 'ruby', 'lib', 'voxgig_omni')

require_relative '../lib/voxgig_station'

# The shared station spec, walking up from this file.
def specfile(name)
  dir = HERE
  8.times do
    cand = File.join(dir, 'spec', name)
    return cand if File.exist?(cand)

    dir = File.dirname(dir)
  end
  raise 'station: spec not found: ' + name
end
