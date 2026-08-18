# ProjectName SDK station feature
#
# Binds this SDK to a voxgig/station control surface: registration,
# wire-truth http events, and placeholder credential injection. Thin by
# design - all logic it calls lives in the station library (station
# design §2, the voxgig_station hex package this SDK's mix.exs depends
# on); Voxgig.Station.Adapter.feature_binding resolves the station from
# the feature options or the ambient instance, verifies wrap position,
# registers, and wraps the transport. No station open -> nil binding,
# and the feature is an inert no-op (station design §3.1).
#
# Every closure is installed HERE, in new/0, never later: an
# extend-supplied instance (the adopt path) passes through the generated
# make_options' deep clone, and a closure installed after cloning would
# be invisible to the copy the client's features list holds. Each
# closure captures THIS original node, so shared state (_binding) still
# flows to the clone's dispatch.

defmodule ProjectName.Feature.Station do
  alias Voxgig.Struct, as: S
  alias ProjectName.Feature, as: F

  def new do
    f = F.base("station")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)

    Enum.each(["PrePoint", "PreDone", "PreUnexpected"], fn hook ->
      F.install(f, hook, fn ctx -> run_hook(f, hook, ctx) end)
    end)

    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)
    S.setprop(f, "_binding", Voxgig.Station.Adapter.feature_binding(ctx, options))
    nil
  end

  # Hook bridge (station design §3 item 3): operation semantics
  # correlated with the HTTP events via the per-op id on the SDK's own
  # ctx. Hook dispatch ignores return values.
  defp run_hook(f, name, ctx) do
    binding = S.getprop(f, "_binding")
    if binding != nil, do: Voxgig.Station.Adapter.hook(binding, name, ctx)
    nil
  end
end
