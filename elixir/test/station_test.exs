# RUN: make test
# RUN-SOME: mix test test/station_test.exs
#
# Focused unit tests for the contracts the JSON corpus cannot express
# (design station.md 13): the ambient instance, the event ring + tap,
# the env-only broker's hit/miss/refusal semantics, and the profile
# lookup walk. The struct-facing adapter half is exercised by the
# generated-SDK integration flow, not here - no SDK (and so no
# Voxgig.Struct) is present in a standalone library checkout.

defmodule Voxgig.StationTest do
  use ExUnit.Case, async: false

  alias Voxgig.Station
  alias Voxgig.Station.Descriptor
  alias Voxgig.Station.Error
  alias Voxgig.Station.Events
  alias Voxgig.Station.Profile
  alias Voxgig.Station.Secrets

  setup do
    Station.reset()
    :ok
  end

  # --- ambient instance (design station.md 10.2) ---

  test "open is idempotent; conflicting options are an error" do
    assert nil == Station.current()

    st = Station.open(%{"config" => nil})
    assert st == Station.open(%{"config" => nil})
    assert st == Station.current()

    err =
      assert_raise Error, fn ->
        Station.open(%{"config" => nil, "profile" => "prod"})
      end

    assert "station_open_conflict" == err.code

    Station.reset()
    assert nil == Station.current()
  end

  test "new stays isolated from the ambient instance" do
    ambient = Station.open(%{"config" => nil})
    isolated = Station.new(%{"config" => nil})
    assert ambient != isolated
    assert ambient == Station.current()
  end

  test "close is idempotent and drops the ambient slot" do
    st = Station.open(%{"config" => nil})
    assert false == Station.closed?(st)
    Station.close(st)
    assert true == Station.closed?(st)
    Station.close(st)
    assert nil == Station.current()
  end

  # --- construction events ---

  test "auto proxy degrades to solo with one warning event" do
    st = Station.new(%{"config" => nil})
    [first | _] = Station.events(st)
    assert "station" == first["kind"]
    assert first["meta"]["warn"] =~ "running solo"
  end

  test "proxy off emits no degradation warning" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})
    assert [] == Station.events(st)
  end

  test "env-only honesty: unsupported provider kinds are said at construction" do
    config = %{
      "station" => 1,
      "profiles" => %{
        "default" => %{
          "secrets" => %{"providers" => [%{"kind" => "env"}, %{"kind" => "hashicorp"}]}
        }
      }
    }

    st = Station.new(%{"config" => config, "proxy" => "off"})
    [ev] = Station.events(st)
    assert ev["meta"]["warn"] =~ "no elixir sekreto port"
    assert ev["meta"]["warn"] =~ "hashicorp"
  end

  test "close warns on profile plugin keys matching no registered plugin" do
    config = %{
      "station" => 1,
      "profiles" => %{"default" => %{"plugin" => %{"typod" => %{"base" => "http://x"}}}}
    }

    st = Station.new(%{"config" => config, "proxy" => "off"})
    Station.close(st)
    [ev] = Station.events(st)
    assert ev["meta"]["warn"] =~ "typod"
    assert ev["meta"]["warn"] =~ "matched no registered plugin"
  end

  # --- the event ring (design station.md 6) ---

  test "ring is bounded, drops oldest, and counts drops in status" do
    buf = Events.buffer(3)

    {buf, _} = Events.emit(buf, %{"n" => 1})
    {buf, _} = Events.emit(buf, %{"n" => 2})
    {buf, _} = Events.emit(buf, %{"n" => 3})
    {buf, _} = Events.emit(buf, %{"n" => 4})
    {buf, _} = Events.emit(buf, %{"n" => 5})

    assert [%{"n" => 3}, %{"n" => 4}, %{"n" => 5}] == Events.events(buf)
    assert %{"buffered" => 3, "dropped" => 2} == Events.status(buf)
  end

  test "tap sees events, unsubscribes cleanly, and a raising tap never fails emit" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})
    me = self()

    untap_raise = Station.tap(st, fn _ev -> raise "tap boom" end)
    untap = Station.tap(st, fn ev -> send(me, {:ev, ev}) end)

    Station.emit(st, %{"t" => 1, "kind" => "station", "meta" => %{"warn" => "w1"}})
    assert_received {:ev, %{"meta" => %{"warn" => "w1"}}}

    untap.()
    untap_raise.()
    Station.emit(st, %{"t" => 2, "kind" => "station", "meta" => %{"warn" => "w2"}})
    refute_received {:ev, %{"meta" => %{"warn" => "w2"}}}

    assert 2 == Station.status(st)["events"]["buffered"]
  end

  test "status shape" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})
    status = Station.status(st)
    assert "solo" == status["mode"]
    assert "default" == status["profile"]
    assert [] == status["plugins"]
    assert %{"buffered" => 0, "dropped" => 0} == status["events"]
  end

  # --- the env-only broker (design station.md 2.2, 5.2) ---

  test "env provider resolves the sekreto env key, and caches per plugin" do
    System.put_env("STATIONTEST_ONE_APIKEY", "v-one")

    broker = Secrets.broker()
    providers = [%{"kind" => "env"}]

    {:ok, "v-one", broker} =
      Secrets.value(broker, providers, "stationtest-one", "stationtest_one.apikey")

    # Cached: a changed environment is not re-read until refresh.
    System.put_env("STATIONTEST_ONE_APIKEY", "v-two")

    {:ok, "v-one", broker} =
      Secrets.value(broker, providers, "stationtest-one", "stationtest_one.apikey")

    broker = Secrets.refresh(broker)

    {:ok, "v-two", _broker} =
      Secrets.value(broker, providers, "stationtest-one", "stationtest_one.apikey")

    System.delete_env("STATIONTEST_ONE_APIKEY")
  end

  test "a miss is not an error: station_secret_no_value when every store missed" do
    System.delete_env("STATIONTEST_MISSING_APIKEY")

    {:error, err} =
      Secrets.value(Secrets.broker(), [%{"kind" => "env"}], "p", "stationtest_missing.apikey")

    assert "station_secret_no_value" == err.code
    assert Exception.message(err) =~ "stationtest_missing.apikey"
  end

  test "a store this port cannot answer from is an error, never a fall-through" do
    # env misses first, then the chain reaches dotenv - which must stop
    # the chain (station.md 5.2), not silently skip to nothing.
    System.delete_env("STATIONTEST_CHAIN_APIKEY")

    {:error, err} =
      Secrets.value(
        Secrets.broker(),
        [%{"kind" => "env"}, %{"kind" => "dotenv", "file" => ".env"}],
        "p",
        "stationtest_chain.apikey"
      )

    assert "station_secret_error" == err.code
    assert Exception.message(err) =~ "env-only"
  end

  test "an env provider earlier in the chain answering never reaches the refusal" do
    System.put_env("STATIONTEST_FIRST_APIKEY", "hit")

    {:ok, "hit", _} =
      Secrets.value(
        Secrets.broker(),
        [%{"kind" => "env"}, %{"kind" => "hashicorp"}],
        "p",
        "stationtest_first.apikey"
      )

    System.delete_env("STATIONTEST_FIRST_APIKEY")
  end

  test "an invalid secret name is a station_secret_error" do
    {:error, err} = Secrets.value(Secrets.broker(), [%{"kind" => "env"}], "p", "Not A Name")
    assert "station_secret_error" == err.code
  end

  test "hoisted values win over the chain" do
    broker = Secrets.hoist(Secrets.broker(), "solardemo", "resident-key")
    {:ok, "resident-key", _} = Secrets.value(broker, [%{"kind" => "env"}], "solardemo", "x.apikey")
  end

  test "scrub is exact-value with no length floor" do
    broker = Secrets.broker()
    broker = Secrets.hoist(broker, "a", "k")
    broker = Secrets.hoist(broker, "b", "long-secret-value")

    out = Secrets.scrub(broker, "got k and long-secret-value back")
    refute out =~ "long-secret-value"
    assert out =~ "[redacted]"
    refute String.contains?(out, " k ")
  end

  test "redact runs the broker scrub through the station" do
    st = Station.new(%{"config" => nil, "proxy" => "off"})
    Station.hoist(st, "solardemo", "sekrit")
    assert false == String.contains?(Station.redact(st, "a sekrit b"), "sekrit")
    # The hoist itself is a visible warning event, never a silent downgrade.
    assert Enum.any?(Station.events(st), fn ev ->
             "station" == ev["kind"] and (ev["meta"]["warn"] || "") =~ "hoisted"
           end)
  end

  # --- profile lookup (design station.md 3.5) ---

  test "find_config_file walks cwd upward" do
    base = Path.join(System.tmp_dir!(), "station-test-#{System.unique_integer([:positive])}")
    nested = Path.join([base, "a", "b"])
    File.mkdir_p!(nested)
    File.write!(Path.join(base, "station.json"), ~s({ "station": 1 }))

    assert Path.join(base, "station.json") == Profile.find_config_file(nested)

    config = Profile.load_config(nested)
    assert %{"station" => 1} == config

    File.rm_rf!(base)
  end

  test "profile selection: option beats VOXGIG_STATION_PROFILE beats default" do
    System.delete_env("VOXGIG_STATION_PROFILE")
    assert "default" == Profile.select(nil)

    System.put_env("VOXGIG_STATION_PROFILE", "stage")
    assert "stage" == Profile.select(nil)
    assert "prod" == Profile.select("prod")
    System.delete_env("VOXGIG_STATION_PROFILE")
  end

  # --- canonical serializer edges beyond the corpus ---

  test "canonical serializer escapes control characters JSON-style" do
    assert "\"a\\u0001b\\nc\"" == Descriptor.canonical_serialize("a" <> <<1>> <> "b\nc")
  end

  test "envtoken trims and collapses non-alphanumerics" do
    assert "GNARLY_PETS" == Descriptor.envtoken("gnarly-pets")
    assert "WEIRD_NAME_2" == Descriptor.envtoken("Weird--Name..2")
    assert "" == Descriptor.envtoken(nil)
  end

  test "normalize: auth-inactive config plans no credential but keeps the view" do
    {descriptor, warnings} =
      Descriptor.normalize(%{
        "main" => %{"name" => "Solardemo", "slug" => "solardemo", "version" => "1.2.3",
          "target" => "elixir"},
        "options" => %{"base" => "http://localhost:8901"},
        "entity" => %{},
        "feature" => %{}
      })

    assert [] == warnings
    assert false == descriptor["auth"]["active"]
    assert "solardemo.apikey" == descriptor["auth"]["secretname"]
    assert "elixir" == descriptor["target"]
  end
end
