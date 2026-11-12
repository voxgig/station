# RUN: make test
# RUN-SOME: mix test test/placement_test.exs
#
# A port of the adapterAnchor half of typescript/test/placement.test.ts,
# which is canonical, plus the anchor connect() hands the carried adapter.
# The adapter is built of Voxgig.Struct nodes; test_helper.exs loads them.

defmodule Voxgig.Station.PlacementTest do
  use ExUnit.Case, async: false
  @compile {:no_warn_undefined, Voxgig.Struct}

  alias Voxgig.Station
  alias Voxgig.Station.Adapter

  setup_all do
    Voxgig.Station.TestStruct.load()
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
