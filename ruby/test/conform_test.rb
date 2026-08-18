# frozen_string_literal: true

# RUN: ruby test/conform_test.rb
# RUN-SOME: ruby test/conform_test.rb -n test_secretname
#
# The station conformance suite: the pure-contract half of the design's
# (station.md 13) corpus, from spec/station.json, through voxgig/omni -
# the same file every port runs. Sections that need live SDK machinery
# (inject, order, event correlation) live in the integration suites
# against real generated SDKs; the corpus carries what a port can prove
# with no SDK present.

require 'minitest/autorun'

require_relative 'helper'

R = VoxgigOmni.make_runner(specfile('station.json')).call('station')
SPEC = R[:spec]
RUNSET = R[:runset]

# Spec nulls arrive as omni's NULLMARK sentinel; restore them so a
# subject sees what the spec means.
def denull(val)
  return nil if VoxgigOmni::NULLMARK == val
  return val.map { |v| denull(v) } if val.is_a?(Array)

  if val.is_a?(Hash)
    out = {}
    val.each { |k, v| out[k] = denull(v) }
    return out
  end

  val
end

class TestStationConform < Minitest::Test
  def test_secretname
    RUNSET.call(SPEC['secretname'], lambda { |vin|
      secretname = VoxgigStation.secretname_default(vin['slug'])
      {
        'envtoken' => VoxgigStation.envtoken(vin['slug']),
        'secretname' => secretname,
        'envkey' => VoxgigSekreto.envkey(secretname)
      }
    })
  end

  def test_placeholder
    RUNSET.call(SPEC['placeholder'], ->(slug) { VoxgigStation.placeholder_for(slug) })
  end

  def test_descriptor
    RUNSET.call(SPEC['descriptor'], lambda { |vin|
      VoxgigStation.normalize_descriptor(vin['config'], vin['feature'])[:descriptor]
    })
  end

  def test_descriptorwarnings
    RUNSET.call(SPEC['descriptorwarnings'], lambda { |vin|
      VoxgigStation.normalize_descriptor(vin['config'], vin['feature'])[:warnings].length
    })
  end

  def test_canonical
    RUNSET.call(SPEC['canonical'], lambda { |vin|
      VoxgigStation.canonical_serialize(denull(vin))
    })
  end

  def test_profile
    RUNSET.call(SPEC['profile'], lambda { |vin|
      VoxgigStation.resolve_profile(denull(vin['config']), vin['profile'])
    })
  end

  def test_errors
    RUNSET.call(SPEC['errors'], ->(code) { VoxgigStation.known_code?(code) })
  end
end
