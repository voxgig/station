# RUN: make test
# RUN-SOME: mix test test/placement_test.exs
#
# A port of the adapterAnchor half of typescript/test/placement.test.ts,
# which is canonical, plus the anchor connect() hands the carried adapter.
# The adapter is built of Voxgig.Struct nodes, which a generated SDK
# supplies; here the struct port is compiled from its sibling checkout,
# the way conform_test.exs compiles omni.

defmodule Voxgig.Station.PlacementTest do
  use ExUnit.Case, async: false
  @compile {:no_warn_undefined, Voxgig.Struct}

  alias Voxgig.Station
  alias Voxgig.Station.Adapter

  defp structhome do
    here = __DIR__

    candidates = [
      System.get_env("STRUCT_HOME"),
      Path.expand("../../../struct", here),
      Path.expand("../../../../struct", here),
      "/workspace/struct",
      "/home/user/struct"
    ]

    case Enum.find(candidates, fn c ->
           is_binary(c) and File.exists?(Path.join(c, "elixir/lib/voxgig_struct.ex"))
         end) do
      nil -> raise "station: voxgig/struct not found - set STRUCT_HOME"
      found -> Path.expand(found)
    end
  end

  setup_all do
    unless Code.ensure_loaded?(Voxgig.Struct) do
      Code.require_file(Path.join([structhome(), "elixir", "lib", "voxgig_struct.ex"]))
    end

    :ok
  end

  setup do
    Station.reset()
    :ok
  end

  defp anchor(fmap), do: Adapter.plain(Adapter.adapter_anchor(Adapter.to_node(fmap)))

  test "after test when test is active, else before the first by name" do
    assert %{} == anchor(nil)
    assert %{} == anchor(%{})
    assert %{} == anchor(%{"station" => %{"active" => true}})
    assert %{"__before__" => "retry"} == anchor(%{"retry" => %{"active" => true}})

    assert %{"__before__" => "cache"} ==
             anchor(%{"retry" => %{"active" => true}, "cache" => %{"active" => true}})

    assert %{"__before__" => "retry"} ==
             anchor(%{"cache" => %{"active" => false}, "retry" => %{"active" => true}})

    assert %{"__before__" => "timeout"} ==
             anchor(%{"station" => %{"active" => true}, "timeout" => %{"active" => true}})

    assert %{"__after__" => "test"} ==
             anchor(%{"test" => %{"active" => true}, "retry" => %{"active" => true}})

    assert %{"__before__" => "retry"} ==
             anchor(%{"test" => %{"active" => false}, "retry" => %{"active" => true}})

    assert %{} == anchor([%{"name" => "retry", "active" => true}])
  end

  test "connect hands the carried adapter the anchor of the caller's features" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})

    options =
      Adapter.construct_options(st, %{
        "feature" => %{"retry" => %{"active" => true}, "cache" => %{"active" => true}}
      })

    [adapter] = Adapter.plain(Voxgig.Struct.getprop(options, "extend"))
    assert %{"__before__" => "cache"} == adapter["_options"]
  end
end
