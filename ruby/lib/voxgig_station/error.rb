# frozen_string_literal: true

# Error codes follow the SDKs' house grammar (design station.md 14):
# <subject>_<condition>, absence as no_<thing>, gates as _allow.
# The `errors` corpus section pins the exact strings.
#
# A port of typescript/src/error.ts, which is canonical.

module VoxgigStation
  CODES = %w[
    station_no_proxy
    station_secret_no_value
    station_secret_error
    station_secret_name
    station_host_allow
    station_grant_expired
    station_wrap_order
    station_protocol
    station_no_plugin
    station_no_entity
    station_no_op
    station_agent_allow
    station_body_limit
    station_replay_lossy
    station_open_conflict
    station_bound_twice

    # Declarative config (design 6.4). Only the reference ports raise
    # the config-validation codes so far (Stage 1); the catalog is
    # repo-wide, so every port knows them.
    station_config_invalid
    station_config_secret
    station_secret_collision
    station_feature_reserved

    # Instances (design 6.4). `as` is a tag, not a free name.
    station_instance_api
  ].freeze

  class StationError < StandardError
    attr_reader :code

    def initialize(code, message)
      super(code + ': ' + message)
      @code = code
    end
  end

  module_function

  def known_code?(code)
    CODES.include?(code)
  end
end
