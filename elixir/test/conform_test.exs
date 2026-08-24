# RUN: make test
# RUN-SOME: mix test test/conform_test.exs
#
# The station conformance suite: the pure-contract half of the design's
# (station.md 13) corpus, from spec/station.json, through voxgig/omni -
# the same file every port runs. Sections that need live SDK machinery
# (inject, order, event correlation) live in the generated-SDK
# integration flow; the corpus carries what a port can prove with no SDK
# present.
#
# omni is a sibling checkout, not a published package (yet), so its
# Elixir sources are compiled at runtime from $OMNI_HOME or the usual
# workspace locations (the other ports' idiom).

defmodule Voxgig.Station.ConformTest do
  use ExUnit.Case, async: false

  alias Voxgig.Station.Descriptor
  alias Voxgig.Station.Error
  alias Voxgig.Station.Profile
  alias Voxgig.Station.Secrets

  defp omnihome do
    here = __DIR__

    candidates = [
      System.get_env("OMNI_HOME"),
      Path.expand("../../../omni", here),
      Path.expand("../../../../omni", here),
      "/workspace/omni",
      "/home/user/omni"
    ]

    case Enum.find(candidates, fn c ->
           is_binary(c) and File.exists?(Path.join(c, "spec/fib.json"))
         end) do
      nil -> raise "station: voxgig/omni not found - set OMNI_HOME"
      found -> Path.expand(found)
    end
  end

  defp specfile do
    Path.expand("../../spec/station.json", __DIR__)
  end

  setup_all do
    omni = omnihome()

    # Compile the omni runner from the sibling checkout, once. The
    # modules are plain (no mix project on the omni side); require_file
    # is idempotent per path within one VM run.
    Enum.each(["lib/util.ex", "lib/json.ex", "lib/runner.ex"], fn f ->
      Code.require_file(Path.join([omni, "elixir", f]))
    end)

    runner = Voxgig.Omni.Runner.make_runner(specfile(), %{})
    {:ok, pack: runner.("station", nil)}
  end

  # Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
  # serializer sees what the spec means.
  defp denull(v) do
    nullmark = Voxgig.Omni.Util.nullmark()

    cond do
      v == nullmark -> nil
      is_list(v) -> Enum.map(v, &denull/1)
      is_map(v) -> Map.new(v, fn {k, x} -> {k, denull(x)} end)
      true -> v
    end
  end

  test "secretname", %{pack: pack} do
    pack.runset.(pack.set.("secretname"), fn args ->
      vin = hd(args)
      secretname = Descriptor.secretname_default(vin["slug"])

      %{
        "envtoken" => Descriptor.envtoken(vin["slug"]),
        "secretname" => secretname,
        "envkey" => Secrets.envkey(secretname)
      }
    end)
  end

  test "placeholder", %{pack: pack} do
    pack.runset.(pack.set.("placeholder"), fn args ->
      Secrets.placeholder_for(hd(args))
    end)
  end

  test "descriptor", %{pack: pack} do
    pack.runset.(pack.set.("descriptor"), fn args ->
      vin = hd(args)
      {descriptor, _warnings} = Descriptor.normalize(vin["config"], vin["feature"])
      descriptor
    end)
  end

  test "descriptorwarnings", %{pack: pack} do
    pack.runset.(pack.set.("descriptorwarnings"), fn args ->
      vin = hd(args)
      {_descriptor, warnings} = Descriptor.normalize(vin["config"], vin["feature"])
      length(warnings)
    end)
  end

  test "canonical", %{pack: pack} do
    pack.runset.(pack.set.("canonical"), fn args ->
      Descriptor.canonical_serialize(denull(hd(args)))
    end)
  end

  # The 3.3 merge, and the whole of this port's profile contract.
  #
  # The `profile` section is NOT run here: it pins the pre-Stage-1
  # `plugin` grammar, which this port no longer speaks. It stays in the
  # corpus for the ports that have not crossed the rename yet and is
  # deleted when the last one does - see spec/README.md.
  test "instance", %{pack: pack} do
    pack.runset.(pack.set.("instance"), fn args ->
      vin = hd(args)
      Profile.resolve(denull(vin["config"]), vin["profile"])
    end)
  end

  test "errors", %{pack: pack} do
    pack.runset.(pack.set.("errors"), fn args ->
      Error.known_code?(hd(args))
    end)
  end
end
