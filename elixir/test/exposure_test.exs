# RUN: make test
# RUN-SOME: mix test test/exposure_test.exs
#
# A port of the activation-entry half of typescript/test/exposure.test.ts,
# which is canonical: what connect() and the inverted binding hand the SDK.
# The options are Voxgig.Struct nodes; test_helper.exs loads them.

defmodule Voxgig.Station.ExposureTest do
  use ExUnit.Case, async: false
  @compile {:no_warn_undefined, Voxgig.Struct}

  alias Voxgig.Station
  alias Voxgig.Station.Adapter

  @secret "exposure-key-101"

  setup_all do
    Voxgig.Station.TestStruct.load()
  end

  setup do
    Station.reset()
    :ok
  end

  defp entry(options),
    do: Voxgig.Struct.getprop(Voxgig.Struct.getprop(options, "feature"), "station")

  test "connect: the activation entry keeps no caller key" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})
    options = Adapter.construct_options(st, %{"apikey" => @secret})

    assert @secret == Voxgig.Struct.getprop(options, "apikey"), "the SDK still gets its key"
    refute inspect(Adapter.plain(entry(options))) =~ @secret
    [adapter] = Adapter.plain(Voxgig.Struct.getprop(options, "extend"))
    refute inspect(adapter) =~ @secret
  end

  test "inverted binding: the activation entry keeps no caller key" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})
    options = Adapter.binding_options(st, %{"apikey" => @secret})

    assert @secret == Voxgig.Struct.getprop(options, "apikey"), "the SDK still gets its key"
    refute inspect(Adapter.plain(entry(options))) =~ @secret
    assert is_function(Voxgig.Struct.getprop(entry(options), "station"), 0)
  end
end
