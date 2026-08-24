# frozen_string_literal: true

# voxgig_station - one control surface for outbound integrations.
#
# The Ruby station library (design voxgig/station docs/design/station.md):
# solo mode, hand-written per the modem principle (design 10). sekreto
# (require 'voxgig_sekreto') and struct (require 'voxgig_struct', which
# backs validate_config) are the two dependencies it takes.

require_relative 'voxgig_station/error'
require_relative 'voxgig_station/events'
require_relative 'voxgig_station/descriptor'
require_relative 'voxgig_station/structhome'
require_relative 'voxgig_station/shape'
require_relative 'voxgig_station/feature'
require_relative 'voxgig_station/factory'
require_relative 'voxgig_station/loader'
require_relative 'voxgig_station/profile'
require_relative 'voxgig_station/secrets'
require_relative 'voxgig_station/station'
require_relative 'voxgig_station/adapter'
