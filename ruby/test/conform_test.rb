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

require 'json'

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

# One driver per section this port RUNS, keyed by the corpus section
# name - the tests below are REGISTERED from this table, so a section
# listed here cannot silently not run, and `sections-covered` closes the
# other direction.
DRIVERS = {
  'secretname' => lambda { |vin|
    secretname = VoxgigStation.secretname_default(vin['slug'])
    {
      'envtoken' => VoxgigStation.envtoken(vin['slug']),
      'secretname' => secretname,
      'envkey' => VoxgigSekreto.envkey(secretname),
    }
  },

  'placeholder' => ->(slug) { VoxgigStation.placeholder_for(slug) },

  'descriptor' => lambda { |vin|
    VoxgigStation.normalize_descriptor(vin['config'], vin['feature'])[:descriptor]
  },

  'descriptorwarnings' => lambda { |vin|
    VoxgigStation.normalize_descriptor(vin['config'], vin['feature'])[:warnings].length
  },

  'canonical' => ->(vin) { VoxgigStation.canonical_serialize(denull(vin)) },

  # Normalize, then validate (design station.md 4.2). The entry is a RAW
  # config in, and either the normalized output or the expected error
  # out - the two steps are ONE PIPELINE, and a port that splits them is
  # free to validate the wrong form.
  'config' => lambda { |vin|
    VoxgigStation.validate_config(VoxgigStation.normalize_config(denull(vin)))
  },

  # The 3.3 merge, and the whole of this port's profile contract.
  'instance' => lambda { |vin|
    VoxgigStation.resolve_profile(denull(vin['config']), vin['profile'])
  },

  # design station.md 8's pure half (10.1): the three-level merge with
  # its depth boundary, and the 8.4 order resolution. ONE DRIVER, TWO
  # ENTRY SHAPES - `merged` selects the resolver, anything else the
  # merge - because a port that guessed from looser cues would run the
  # wrong subject on a mistyped entry.
  'feature' => lambda { |vin|
    if vin['merged'].nil?
      VoxgigStation.merge_features(VoxgigStation.feature_sources(
        denull(vin['base']), denull(vin['overlay']), vin['api'], vin['ref']))
    else
      ordered = VoxgigStation.resolve_order(denull(vin['merged']))
      VoxgigStation.check_pin(ordered)
      ordered.map { |o| o['name'] }
    end
  },

  # 6.1's `as` rule: pure over (api, opts), so it is corpus-shaped rather
  # than driver-shaped even though it decides a registry key.
  'instanceref' => ->(vin) { VoxgigStation.instance_ref(vin['api'], vin['opts']) },

  'errors' => ->(code) { VoxgigStation.known_code?(code) },
}.freeze

# The sections this port deliberately does NOT run, with the reason - an
# entry here is a recorded decision, not an omission.
PENDING = {
  # Pins the pre-Stage-1 `plugin` grammar, which this port no longer
  # speaks. It stays in the corpus for the ports that have not crossed
  # the rename yet and is deleted when the last one does - see
  # spec/README.md. Everything it pins is restated in the sdk/api grammar
  # the `instance` section runs.
  'profile' => 'pre-rename plugin grammar; superseded by the instance section',
}.freeze

class TestStationConform < Minitest::Test
  # Section completeness: the sections run plus the explicit PENDING list
  # must EXACTLY cover what spec/station.json carries. A section added to
  # the corpus and not picked up here fails loudly instead of silently
  # not running; a section renamed or removed while this port still lists
  # it fails too, so a stale driver or a stale pin is caught rather than
  # rotting.
  #
  # The corpus is read as RAW JSON, not through the omni runner: the
  # runner resolves and normalizes a NAMED section, so it would hide a
  # section it never resolved.
  def test_sections_covered
    spec = JSON.parse(File.read(specfile('station.json')))
    present = spec['primary']['station'].keys.sort
    covered = (DRIVERS.keys + PENDING.keys).sort
    assert_equal present, covered
  end

  # REGISTERED FROM THE TABLE, never written out by hand: a section
  # listed in DRIVERS cannot silently fail to execute.
  DRIVERS.each_key do |section|
    define_method('test_' + section) do
      refute_nil SPEC[section], 'corpus section missing: ' + section
      RUNSET.call(SPEC[section], DRIVERS[section])
    end
  end
end
