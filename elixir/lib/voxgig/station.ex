# voxgig/station - one control surface for outbound integrations.
#
# The station library core, solo mode (design D1): fully functional
# in-process with no other component running. The proxy (D2) is a
# deferred amplifier - `require` therefore fails on the operation path
# (design station.md 2.1/14), and `auto` degrades to solo with one
# warning event.
#
# A port of typescript/src/Station.ts, which is canonical, split along
# the Elixir seam the generated SDKs force: everything in THIS module and
# its pure siblings (Descriptor/Profile/Secrets/Events/Error/Json) is
# plain Elixir data and compiles and unit-tests with no SDK present;
# everything that touches the SDKs' Voxgig.Struct nodes lives in
# Voxgig.Station.Adapter, which resolves the vendored struct module at
# runtime inside a generated SDK.
#
# STATE. A station instance is a tagged reference `{:station, id}` whose
# state lives in a public named ETS table - deliberately the exact
# arrangement of the SDKs' vendored Voxgig.Struct heap, because it has
# the same reasons: hooks are synchronous closures run in whatever
# process performed the operation, so instance state must be mutable and
# reference-stable across processes with no server round-trip. It also
# inherits the same documented hazard: the table is owned by the first
# process to touch this module, and dies with it (the generated SDKs'
# config.ex documents the identical failure mode for struct handles). A
# dead handle raises on use; current() treats a dead ambient instance as
# "no station open", which per design station.md 3.1 makes bound
# features inert no-ops rather than failures.
#
# SECRETS. There is no Elixir sekreto port, so this library is env-only
# for secrets and says so (design station.md 2.2) - see
# Voxgig.Station.Secrets for the exact refusal semantics.

defmodule Voxgig.Station do
  alias Voxgig.Station.Descriptor
  alias Voxgig.Station.Error
  alias Voxgig.Station.Events
  alias Voxgig.Station.Profile
  alias Voxgig.Station.Secrets

  @table :voxgig_station_state
  @ambient_key {__MODULE__, :ambient}

  # --- ambient instance (design station.md 10.2) ---

  # open() is the idempotent process-wide singleton; a second open() with
  # conflicting options is an error; new/1 stays isolated for tests and
  # multi-tenant hosts. open() is non-blocking - solo involves no
  # network, and the deferred proxy probe must never change that.
  def open(opts \\ nil) do
    key = opts_key(opts)

    case ambient() do
      nil ->
        station = new(opts)
        :persistent_term.put(@ambient_key, {station, key})
        station

      {station, ^key} ->
        station

      {_station, _other} ->
        Error.fail(
          "station_open_conflict",
          "Station.open() was already called with different options"
        )
    end
  end

  # The ambient instance, or nil - never creates one. The generated
  # station feature binds through this when no explicit handle rides its
  # options (design station.md 3.1: binding is never implicit; only
  # open() creates the ambient instance). A dead handle (heap table gone
  # with its owner) reads as "no station open".
  def current do
    case ambient() do
      nil -> nil
      {station, _key} -> station
    end
  end

  # Test seam: drop the ambient instance.
  def reset do
    :persistent_term.erase(@ambient_key)
    nil
  end

  defp ambient do
    case :persistent_term.get(@ambient_key, nil) do
      nil ->
        nil

      {station, key} ->
        if alive?(station), do: {station, key}, else: nil
    end
  end

  defp opts_key(opts) do
    Descriptor.canonical_serialize(normalize_opts(opts))
  end

  # --- construction ---

  def new(opts \\ nil) do
    ensure_table()
    o = normalize_opts(opts)

    config =
      if Map.has_key?(o, "config"), do: o["config"], else: Profile.load_config(o["folder"])

    profile = Profile.resolve(config, Profile.select(o["profile"]))
    proxy = if nil != o["proxy"], do: o["proxy"], else: "auto"

    state = %{
      opts: o,
      profile: profile,
      require_proxy: "require" == proxy,
      closed: false,
      registry: %{},
      order: [],
      secret_override: %{},
      broker: Secrets.broker(),
      buffer: Events.buffer()
    }

    id = :erlang.unique_integer([:positive, :monotonic])
    station = {:station, id}
    :ets.insert(@table, {id, state})

    if "auto" == proxy do
      # The probe is deferred with the proxy itself; absence degrades to
      # solo with a single warning event naming the cause (station.md 14).
      emit(station, %{
        "t" => now_ms(),
        "kind" => "station",
        "meta" => %{"warn" => "proxy absent (not found); running solo"}
      })
    end

    # Env-only honesty (design station.md 2.2): a chain naming stores
    # this port has no sekreto for is SAID, at construction, not
    # discovered at first request.
    case Secrets.unsupported_kinds(profile["providers"]) do
      [] ->
        :ok

      kinds ->
        emit(station, %{
          "t" => now_ms(),
          "kind" => "station",
          "meta" => %{
            "warn" =>
              "no elixir sekreto port: provider kind(s) " <>
                Enum.join(kinds, ", ") <>
                " are unavailable in solo mode - secrets are env-only " <>
                "(station.md 2.2), and resolution reaching such a provider " <>
                "fails rather than falling through"
          }
        })
    end

    station
  end

  defp normalize_opts(nil), do: %{}

  defp normalize_opts(opts) when is_map(opts) and not is_struct(opts) do
    Map.new(opts, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_opts(opts) when is_list(opts) do
    Map.new(opts, fn {k, v} -> {to_string(k), v} end)
  end

  # --- binding forms (design station.md 3.1) ---
  #
  # For Elixir the PRIMARY form is the inverted binding: the generated
  # SDKs are functional (client = ProjectName.new(options)), so
  # options/2 builds the plain options node every generated constructor
  # already accepts. connect/adopt are the same construction as sugar -
  # module names are first-class, so `connect(st, Solardemo)` is natural
  # - and additionally ride the library's carried adapter on
  # options.extend so they work on SDKs generated WITHOUT the station
  # feature (the retrofit path; a resident options apikey is hoisted by
  # the adapter). All node building lives in Voxgig.Station.Adapter.

  def connect(station, sdk_module, opts \\ nil), do: construct(station, sdk_module, opts)

  def adopt(station, sdk_module, opts \\ nil), do: construct(station, sdk_module, opts)

  defp construct(station, sdk_module, opts) do
    if closed?(station) do
      Error.fail("station_no_plugin", "station is closed")
    end

    sdk_module.new(Voxgig.Station.Adapter.construct_options(station, opts))
  end

  # Inverted binding: the plain options map a generated constructor
  # already accepts - the handle and the activation entry; the profile's
  # per-plugin base is applied by the adapter at init (caller opts still
  # win).
  def options(station, extra \\ nil) do
    Voxgig.Station.Adapter.binding_options(station, extra)
  end

  # --- registration (design station.md 3 item 1, called by the adapter) ---

  # The registry entry whose client IS this term, or nil. Used by
  # feature_binding for idempotency: connect/adopt activate the station
  # entry AND ride the carried adapter on extend, so on an SDK whose
  # generated feature factory carries a real station feature the same
  # construction reaches feature_binding twice - the second arrival must
  # no-op, while a genuinely second client of the same SDK still fails
  # register's slug check (design station.md 10.2). Struct client handles
  # are tagged references, so plain equality is identity.
  @doc false
  def bound_entry(station, client) do
    state = state!(station)

    Enum.find_value(state.order, fn slug ->
      entry = state.registry[slug]
      if nil != client and entry.client == client, do: entry, else: nil
    end)
  end

  @doc false
  def register(station, client, config, active_features, fopts_secret) do
    state = state!(station)

    {descriptor, warnings} = Descriptor.normalize(config, active_features)
    slug = descriptor["slug"]

    if Map.has_key?(state.registry, slug) do
      Error.fail(
        "station_bound_twice",
        "plugin \"" <>
          slug <>
          "\" is already registered; binding one client twice is an error (10.2)"
      )
    end

    profile_plugin = state.profile["plugin"][slug]

    # Secret name precedence: the feature option (in-code, design
    # station.md 9 config.options.secret) beats the profile, which beats
    # the descriptor default.
    fopts_secret = if is_binary(fopts_secret) and fopts_secret != "", do: fopts_secret, else: nil

    secretname =
      first_non_empty([fopts_secret, profile_plugin && profile_plugin["secret"]]) ||
        descriptor["auth"]["secretname"]

    auth_active = true == descriptor["auth"]["active"]
    rung = if auth_active, do: "R1", else: "none"

    binding = %{
      plugin: slug,
      placeholder: if(auth_active, do: Secrets.placeholder_for(slug), else: nil),
      secretname: if(auth_active, do: secretname, else: nil),
      rung: rung
    }

    entry = %{slug: slug, descriptor: descriptor, rung: rung, client: client, warnings: warnings}

    put!(station, %{
      state
      | registry: Map.put(state.registry, slug, entry),
        order: state.order ++ [slug],
        secret_override:
          if(nil != fopts_secret,
            do: Map.put(state.secret_override, slug, fopts_secret),
            else: state.secret_override
          )
    })

    Enum.each(warnings, fn warning ->
      emit(station, %{
        "t" => now_ms(),
        "kind" => "station",
        "plugin" => slug,
        "meta" => %{"warn" => warning}
      })
    end)

    emit(station, %{
      "t" => now_ms(),
      "kind" => "construct",
      "plugin" => slug,
      "meta" => %{
        "name" => descriptor["name"],
        "version" => descriptor["version"],
        "rung" => rung
      }
    })

    {binding, profile_plugin}
  end

  @doc false
  def hoist(station, slug, value) do
    state = state!(station)
    put!(station, %{state | broker: Secrets.hoist(state.broker, slug, value)})

    emit(station, %{
      "t" => now_ms(),
      "kind" => "station",
      "plugin" => slug,
      "meta" => %{
        "warn" =>
          "a resident credential was hoisted into the broker and replaced " <>
            "by the placeholder; prefer configuring the secret name and " <>
            "letting the broker resolve it"
      }
    })

    nil
  end

  # --- transport decisions (called by Voxgig.Station.Adapter's wrap) ---

  @doc false
  def require_proxy?(station), do: state!(station).require_proxy

  @doc false
  def plugin_entry(station, slug), do: state!(station).registry[slug]

  @doc false
  def profile_plugin(station, slug), do: state!(station).profile["plugin"][slug]

  # Resolve the plugin's secret value through the env-only broker,
  # re-applying the name precedence on every call (override beats
  # profile beats descriptor default) - the canonical middleware's rule.
  @doc false
  def secret_value(station, slug) do
    state = state!(station)
    entry = state.registry[slug]
    profile_plugin = state.profile["plugin"][slug]

    name =
      first_non_empty([
        state.secret_override[slug],
        profile_plugin && profile_plugin["secret"]
      ]) ||
        (entry && entry.descriptor["auth"]["secretname"])

    case Secrets.value(state.broker, state.profile["providers"], slug, name) do
      {:ok, value, broker} ->
        put!(station, %{state!(station) | broker: broker})
        {:ok, value}

      {:error, err} ->
        {:error, err}
    end
  end

  # --- the query/observe surface (design station.md 3.2, 6) ---

  def plugins(station) do
    state = state!(station)

    Enum.map(state.order, fn slug ->
      entry = state.registry[slug]

      %{
        "slug" => entry.slug,
        "descriptor" => entry.descriptor,
        "rung" => entry.rung,
        "warnings" => entry.warnings
      }
    end)
  end

  def descriptor_of(station, slug) do
    state = state!(station)

    case state.registry[slug] do
      nil ->
        Error.fail(
          "station_no_plugin",
          "unknown plugin \"" <>
            to_string(slug) <> "\"; known: [" <> Enum.join(state.order, ", ") <> "]"
        )

      entry ->
        entry.descriptor
    end
  end

  def canonical_descriptor(station, slug) do
    Descriptor.canonical_serialize(descriptor_of(station, slug))
  end

  def events(station), do: Events.events(state!(station).buffer)

  # Subscribe a live tap; returns a zero-arity unsubscribe function.
  # Callbacks are serialized, and a raising tap never fails the operation
  # that emitted the event.
  def tap(station, fun) do
    state = state!(station)
    ref = make_ref()
    put!(station, %{state | buffer: Events.tap(state.buffer, ref, fun)})

    fn ->
      s = state!(station)
      put!(station, %{s | buffer: Events.untap(s.buffer, ref)})
      nil
    end
  end

  def status(station) do
    state = state!(station)

    %{
      "mode" => "solo",
      "profile" => state.profile["name"],
      "plugins" =>
        Enum.map(state.order, fn slug ->
          %{"slug" => slug, "rung" => state.registry[slug].rung}
        end),
      "events" => Events.status(state.buffer)
    }
  end

  def redact(station, text), do: Secrets.scrub(state!(station).broker, text)

  def refresh_secrets(station) do
    state = state!(station)
    put!(station, %{state | broker: Secrets.refresh(state.broker)})
    nil
  end

  # close: flush (solo: nothing in flight), then warn on profile plugin
  # keys that matched no registered plugin - a typo'd key silently
  # configuring nothing is the worst outcome for a secrets-and-policy
  # file (design station.md 11). Idempotent; drops the ambient slot when
  # this instance holds it.
  def close(station) do
    state = state!(station)

    if not state.closed do
      state.profile["plugin"]
      |> Map.keys()
      |> Enum.sort()
      |> Enum.each(fn slug ->
        if not Map.has_key?(state.registry, slug) do
          emit(station, %{
            "t" => now_ms(),
            "kind" => "station",
            "meta" => %{
              "warn" => "profile plugin key \"" <> slug <> "\" matched no registered plugin"
            }
          })
        end
      end)

      put!(station, %{state!(station) | closed: true})

      case :persistent_term.get(@ambient_key, nil) do
        {^station, _key} -> reset()
        _ -> nil
      end
    end

    nil
  end

  def closed?(station), do: state!(station).closed

  # --- event emission (shared by this module and the adapter) ---

  @doc false
  def emit(station, ev) do
    state = state!(station)
    {buffer, taps} = Events.emit(state.buffer, ev)
    put!(station, %{state | buffer: buffer})

    # Taps run OUTSIDE the state write (they may re-enter events/status),
    # serialized, and a throwing tap must not fail the operation that
    # emitted the event.
    Enum.each(taps, fn fun ->
      try do
        fun.(ev)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    nil
  end

  @doc false
  def emit_http(station, slug, corr, fullurl, method, status, started, bytes) do
    {host, _hostname, path} = parse_url(fullurl)

    emit(
      station,
      with_corr(
        %{
          "t" => started,
          "kind" => "http",
          "plugin" => slug,
          "http" => %{
            "method" => if(is_binary(method) and method != "", do: method, else: "GET"),
            "host" => host,
            "path" => path,
            "status" => status,
            "durationMs" => now_ms() - started,
            "bytes" => bytes
          }
        },
        corr
      )
    )
  end

  @doc false
  def emit_err(station, slug, corr, err) do
    code =
      case err do
        %{code: code} when is_binary(code) and code != "" -> code
        _ -> nil
      end

    # The scrub keeps an upstream echo of a credential out of the event
    # stream (design station.md 7 as revised: exact-value, no length
    # floor).
    message = redact(station, err_text(err))

    ev_err =
      if nil != code, do: %{"code" => code, "message" => message}, else: %{"message" => message}

    emit(
      station,
      with_corr(%{"t" => now_ms(), "kind" => "error", "plugin" => slug, "err" => ev_err}, corr)
    )
  end

  # Op events from the hook bridge (design station.md 3 item 3); the
  # adapter extracts the fields from the SDK's ctx node.
  @doc false
  def op_event(station, slug, corr, op) do
    emit(
      station,
      with_corr(%{"t" => now_ms(), "kind" => "op", "plugin" => slug, "op" => op}, corr)
    )
  end

  defp with_corr(ev, corr) do
    if is_binary(corr) and corr != "", do: Map.put(ev, "corr", corr), else: ev
  end

  defp err_text(err) do
    cond do
      is_exception(err) -> Exception.message(err)
      is_binary(err) -> err
      true -> inspect(err)
    end
  end

  # --- state cell (the struct-heap arrangement; see the module doc) ---

  @doc false
  def alive?({:station, id}) do
    :undefined != :ets.whereis(@table) and [] != :ets.lookup(@table, id)
  end

  def alive?(_), do: false

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  defp state!({:station, id} = station) do
    case :ets.whereis(@table) do
      :undefined ->
        dead!(station)

      _ ->
        case :ets.lookup(@table, id) do
          [{_, state}] -> state
          _ -> dead!(station)
        end
    end
  end

  defp state!(other) do
    raise ArgumentError,
          "Voxgig.Station: not a station handle: " <> inspect(other)
  end

  defp dead!(station) do
    raise ArgumentError,
          "Voxgig.Station: station handle " <>
            inspect(station) <>
            " is not alive - the state table died with the process that " <>
            "owned it (the vendored struct heap's documented failure mode), " <>
            "or the handle belongs to another VM"
  end

  defp put!({:station, id}, state), do: :ets.insert(@table, {id, state})

  defp first_non_empty(vals) do
    Enum.find(vals, fn v -> is_binary(v) and v != "" end)
  end

  @doc false
  def now_ms, do: System.system_time(:millisecond)

  # ( host-with-port, hostname, path ) from a URL. Mirrors ts URL
  # semantics: host keeps a non-default port, hostname strips it, an
  # empty path reads as '/'. IPv6 literals are out of scope for the solo
  # library (a bracketed host parses as-is). A non-URL yields the ts
  # catch-branch's {'', '', fullurl}.
  @doc false
  def parse_url(fullurl) do
    url = if is_binary(fullurl), do: fullurl, else: ""

    case Regex.run(~r{^([A-Za-z][A-Za-z0-9+.\-]*)://([^/?\#]*)([^?\#]*)}, url) do
      [_, scheme, authority, path] ->
        scheme = String.downcase(scheme)
        authority = Regex.replace(~r/^[^@]*@/, authority, "")

        {hostname, port} =
          case Regex.run(~r/^(.*?)(?::(\d+))?$/, authority) do
            [_, h, p] -> {h, String.to_integer(p)}
            [_, h] -> {h, nil}
            _ -> {authority, nil}
          end

        default =
          case scheme do
            "http" -> 80
            "https" -> 443
            _ -> -1
          end

        host =
          if nil != port and port != default,
            do: hostname <> ":" <> Integer.to_string(port),
            else: hostname

        {host, hostname, if("" == path, do: "/", else: path)}

      _ ->
        {"", "", url}
    end
  end
end
