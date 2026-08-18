# frozen_string_literal: true

# voxgig_station - one control surface for outbound integrations.
#
# The Ruby station library (design voxgig/station docs/design/station.md):
# solo mode, hand-written per the modem principle (design 10). sekreto
# (require 'voxgig_sekreto') is the one dependency it takes.

require_relative 'voxgig_station/error'
require_relative 'voxgig_station/events'
require_relative 'voxgig_station/descriptor'
require_relative 'voxgig_station/profile'
require_relative 'voxgig_station/secrets'
require_relative 'voxgig_station/station'
require_relative 'voxgig_station/adapter'
