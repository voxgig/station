# ProjectName SDK station feature

require 'voxgig_station'

require_relative 'base_feature'

# Binds this SDK to a voxgig/station control surface: registration,
# wire-truth http events, and placeholder credential injection. Thin by
# design - all logic it calls lives in the station library (station
# design §2); VoxgigStation.feature_binding resolves the station from
# the feature options or the ambient instance, verifies wrap position,
# registers, and wraps the transport. No station open -> nil binding,
# and the feature is an inert no-op (station design §3.1).
class ProjectNameStationFeature < ProjectNameBaseFeature
  def initialize
    super
    @version = "0.0.1"
    @name = "station"
    @active = true
    @_binding = nil
  end

  def init(ctx, options)
    @_binding = VoxgigStation.feature_binding(ctx, options)
  end

  # Hook bridge (station design §3 item 3): operation semantics
  # correlated with the HTTP events via the per-op id on the SDK's own
  # ctx.

  def PrePoint(ctx)
    @_binding&.PrePoint(ctx)
  end

  def PreDone(ctx)
    @_binding&.PreDone(ctx)
  end

  def PreUnexpected(ctx)
    @_binding&.PreUnexpected(ctx)
  end
end
