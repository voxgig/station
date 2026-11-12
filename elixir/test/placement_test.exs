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

  defmodule CaptureSDK do
    def new(options) do
      send(self(), {:captured, options})
      :client
    end
  end

  test "after test when test is active, else before the first it will add" do
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

    # sdkgen's ordered list form: list order is init order, not the alphabet.
    assert %{"__before__" => "retry"} == anchor([%{"name" => "retry", "active" => true}])

    assert %{"__before__" => "retry"} ==
             anchor([
               %{"name" => "retry", "active" => true},
               %{"name" => "cache", "active" => true}
             ])

    assert %{"__after__" => "test"} ==
             anchor([
               %{"name" => "retry", "active" => true},
               %{"name" => "test", "active" => true}
             ])

    assert %{} == anchor([%{"name" => "station", "active" => true}, %{"name" => "retry"}])
  end

  test "options and connect keep the list form, station in its pinned place" do
    config = %{
      "station" => 1,
      "profiles" => %{
        "default" => %{
          "sdk" => %{"taskpad" => %{}, "taskpad$eu" => %{"options" => %{"prefix" => "/eu"}}}
        }
      }
    }

    st = Station.new(%{"config" => config, "proxy" => "off"})
    retry = %{"name" => "retry", "active" => true}
    test = %{"name" => "test", "active" => true}
    feature = fn opts -> Adapter.plain(Station.options(st, opts))["feature"] end
    names = fn list -> Enum.map(list, & &1["name"]) end

    bare = feature.(%{"feature" => [retry]})
    assert ["station", "retry"] == names.(bare)
    assert true == hd(bare)["active"]

    assert ["test", "station", "retry"] == names.(feature.(%{"feature" => [test, retry]}))

    moved =
      feature.(%{"feature" => [retry, %{"name" => "station", "instance" => "taskpad$eu"}, test]})

    assert ["retry", "test", "station"] == names.(moved)
    assert "taskpad$eu" == Enum.at(moved, 2)["instance"]

    # connect reads the instance from the list, so its block reaches the SDK.
    Station.connect(st, CaptureSDK, %{
      "feature" => [%{"name" => "station", "instance" => "taskpad$eu"}]
    })

    assert_received {:captured, options}
    seen = Adapter.plain(options)
    assert "/eu" == seen["prefix"]
    assert ["station"] == names.(seen["feature"])
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
