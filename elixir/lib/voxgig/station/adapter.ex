# The station side of the plugin contract (design station.md 3), in ONE
# place: feature_binding/2 is what both entry paths delegate to -
#  - the GENERATED station feature (sdkgen-station's elixir template,
#    lib/<name>/feature/station.ex) calls it from its installed init
#    closure and forwards its hook closures to hook/3;
#  - the library's carried adapter (adapter_feature/2, the connect/adopt
#    retrofit for SDKs generated without the feature) is a thin shell
#    over the same call.
# Registration at init, wrap position verified, transport wrapped with
# copy-on-inject, hooks bridged to op events. Anything changed here
# changes both paths - which is the point.
#
# A port of typescript/src/adapter.ts (plus the struct-facing half of
# Station.ts's _transport), which is canonical.
#
# THE STRUCT SEAM. Generated Elixir SDKs represent every runtime object
# (client, utility, ctx, features, options) as a reference-stable
# Voxgig.Struct node - the vendored ETS-backed struct port each SDK
# carries under lib/utility/struct/. That module ships INSIDE the SDK,
# not on hex, so this library resolves it at runtime: any generated SDK
# loads it into the same VM. no_warn_undefined keeps the standalone
# compile (this repo's own mix test, which exercises only the pure
# modules) quiet; calling into this module without a generated SDK
# loaded raises UndefinedFunctionError for Voxgig.Struct, which is the
# truthful failure.
#
# ELIXIR-SPECIFIC MAPPINGS, pinned by the target notes:
#  - the transport is a closure returning a {response, err} TUPLE;
#  - anonymous functions cannot carry a marker property, so the
#    double-wrap flag lives as a companion prop on the reference-stable
#    utility node ("__station_wrap__") rather than on the closure;
#  - the station handle rides the options as a ZERO-ARITY CLOSURE: the
#    generated make_options deep-clones its options node, and closures
#    pass through that clone by reference while nested nodes do not;
#  - the carried adapter installs ALL its closures in adapter_feature/2
#    (never in init): an extend-supplied instance passes through that
#    same deep clone, and a closure installed after cloning would be
#    invisible to the copy the client's features list holds. Every
#    closure captures the ORIGINAL node, so shared state (_binding)
#    still flows;
#  - the generated feature factory FALLS BACK to an inert base feature
#    for unknown names, so an activated station entry on a pre-station
#    SDK appends a stray named "base" (the ts constructor skips such
#    names instead). A base feature has a no-op init - it can never wrap
#    or record the transport - so strays are excluded from the position
#    check (the rb/perl ports' idiom), which keeps the guard's actual
#    meaning: nothing that could wrap sits between the base transport
#    and station.

defmodule Voxgig.Station.Adapter do
  @compile {:no_warn_undefined, Voxgig.Struct}

  alias Voxgig.Station
  alias Voxgig.Station.Error
  alias Voxgig.Station.Secrets

  alias Voxgig.Struct, as: S

  # --- binding forms (the node-building half of Station.options/connect) ---

  # Inverted binding (design station.md 3.1): the plain options node a
  # generated constructor already accepts - the caller's opts plus the
  # activation entry carrying the handle.
  def binding_options(station, extra \\ nil) do
    extra_node = to_node(extra)
    base = if S.ismap(extra_node), do: S.clone(extra_node), else: S.jm([])
    activate(base, station, if(S.ismap(extra_node), do: extra_node, else: S.jm([])))
    base
  end

  # connect/adopt options: the activation entry PLUS the carried adapter
  # on options.extend, for SDKs generated without the station feature
  # (design station.md 3.1 adopt - construction-time sugar, not post-hoc
  # attachment). When the generated feature exists both are active on one
  # client; the second arrival into feature_binding is made inert by
  # Station.bound_entry, so behavior is identical either way.
  def construct_options(station, opts \\ nil) do
    opts_node = to_node(opts)
    calleropts = if S.ismap(opts_node), do: opts_node, else: S.jm([])
    out = if S.ismap(opts_node), do: S.clone(opts_node), else: S.jm([])
    activate(out, station, calleropts)

    adapter = adapter_feature(station, calleropts)
    current = S.getprop(out, "extend")

    if S.islist(current) do
      S.setprop(current, S.size(current), adapter)
    else
      S.setprop(out, "extend", S.jt([adapter]))
    end

    out
  end

  defp activate(options, station, calleropts) do
    fmap = ensure_map(options, "feature")
    entry = ensure_map(fmap, "station")
    S.setprop(entry, "active", true)
    S.setprop(entry, "station", fn -> station end)
    S.setprop(entry, "calleropts", calleropts)
    options
  end

  defp ensure_map(node, key) do
    cur = S.getprop(node, key)

    if S.ismap(cur) do
      cur
    else
      fresh = S.jm([])
      S.setprop(node, key, fresh)
      fresh
    end
  end

  # --- the binding (design station.md 3 items 1-4) ---

  # Resolve the station this activation binds to: an explicit handle in
  # the feature options (connect/adopt and Station.options/2 pass one,
  # as a zero-arity closure), else the ambient instance. No station open
  # -> nil: an activated feature with no opened station is an inert
  # no-op that emits nothing and fails nothing (design station.md 3.1).
  def feature_binding(ctx, fopts) do
    station =
      resolve_station(if(S.ismap(fopts), do: S.getprop(fopts, "station"), else: nil)) ||
        Station.current()

    if nil == station do
      nil
    else
      bind(station, ctx, fopts)
    end
  end

  defp resolve_station(v) do
    cond do
      is_function(v, 0) ->
        handle = safe_call(v)
        if Station.alive?(handle), do: handle, else: nil

      Station.alive?(v) ->
        v

      true ->
        nil
    end
  end

  defp safe_call(f) do
    try do
      f.()
    rescue
      _ -> nil
    end
  end

  defp bind(station, ctx, fopts) do
    client = S.getprop(ctx, "client")

    # Same construction, second arrival (generated feature + carried
    # adapter both active on one client): the first bind won, this one
    # is inert. See Station.bound_entry.
    if nil != Station.bound_entry(station, client) do
      nil
    else
      utility = S.getprop(ctx, "utility")
      options = S.getprop(ctx, "options")
      calleropts = if S.ismap(fopts), do: S.getprop(fopts, "calleropts"), else: nil

      guard_position(client)

      fopts_secret = if S.ismap(fopts), do: S.getprop(fopts, "secret"), else: nil

      {binding, profile_plugin} =
        Station.register(
          station,
          client,
          plain(S.getprop(ctx, "config")),
          plain(S.getprop(options, "feature")),
          fopts_secret
        )

      slug = binding.plugin

      # Base URL precedence (design station.md 3.5): caller opts (7) beat
      # the profile (4), which beats the SDK's config default (1) already
      # in options.base. calleropts is knowable on every binding form
      # (connect/adopt and Station.options/2 all pass it).
      if S.ismap(calleropts) and nil == S.getprop(calleropts, "base") and
           is_map(profile_plugin) and is_binary(profile_plugin["base"]) do
        S.setprop(options, "base", profile_plugin["base"])
      end

      if "none" != binding.rung do
        placeholder = binding.placeholder

        # A real credential already resident in the options is hoisted
        # into the broker and replaced by the placeholder before
        # construction completes (design station.md 3.1 adopt) -
        # options_map/1 and prepare/2 output become placeholder-safe
        # from here on.
        resident = S.getprop(options, "apikey")

        if is_binary(resident) and resident != "" and resident != placeholder do
          Station.hoist(station, slug, resident)
        end

        S.setprop(options, "apikey", placeholder)
      end

      # Wrap the transport. Copy-on-inject (design station.md 5.3)
      # happens inside transport/6; auth-inactive plugins skip credential
      # planning but the wrap still observes.
      if true == S.getprop(utility, "__station_wrap__") do
        Error.fail(
          "station_bound_twice",
          "plugin \"" <> slug <> "\" already carries a station wrap"
        )
      end

      inner = S.getprop(utility, "fetcher")

      S.setprop(utility, "fetcher", fn fctx, fullurl, fetchdef ->
        transport(station, slug, inner, fctx, fullurl, fetchdef)
      end)

      S.setprop(utility, "__station_wrap__", true)

      %{station: station, slug: slug}
    end
  end

  # Position guard (design station.md 3.3): the wrap must sit immediately
  # outside the base transport - inside retry/cache/ratelimit - or its
  # http events stop being wire truth. Position in the client's features
  # list IS init order, so verify it and fail loudly. Inert "base" strays
  # (the factory fallback, see the module doc) are excluded.
  defp guard_position(client) do
    features = S.getprop(client, "features")
    features = if is_list(features), do: features, else: []

    names =
      Enum.map(features, fn f ->
        n = if S.ismap(f), do: S.getprop(f, "name"), else: nil
        if is_binary(n), do: n, else: ""
      end)

    order = Enum.reject(names, &("base" == &1))
    self_at = Enum.find_index(order, &("station" == &1))
    test_at = Enum.find_index(order, &("test" == &1))
    expected = if nil == test_at, do: 0, else: test_at + 1

    if self_at != expected do
      Error.fail(
        "station_wrap_order",
        "station must init immediately after the base transport; " <>
          "feature order is [" <> Enum.join(names, ", ") <> "]"
      )
    end

    nil
  end

  # --- the transport middleware (design station.md 3.3, 5.3) ---
  #
  # Called by the wrap closure; `inner` is the transport that was current
  # at init time. Returns the SDK's {response, err} tuple; a raised
  # exception propagates (after events), the retry feature's convention.
  def transport(station, slug, inner, fctx, fullurl, fetchdef) do
    corr = corr_of(fctx)

    try do
      # Fail-closed means traffic (station.md 2.1): with the proxy
      # deferred, `require` can never attach, so every operation fails
      # here - the operation path, never the constructor.
      if Station.require_proxy?(station) do
        err = Error.new("station_no_proxy", "proxy: \"require\" is set and no proxy is attached")
        Station.emit_err(station, slug, corr, err)
        throw({:station_ret, {nil, err}})
      end

      entry = Station.plugin_entry(station, slug)
      placeholder = Secrets.placeholder_for(slug)
      client = S.getprop(fctx, "client")
      live = nil != client and "live" == S.getprop(client, "mode")
      profile_plugin = Station.profile_plugin(station, slug)

      # Egress policy (design station.md 16), solo half: the hosts
      # allowlist is enforced at the seam every request crosses. When a
      # policy is present, redirects come back manual - a 3xx is a
      # response like any other, so a Location off the allowlist cannot
      # pull an automatic credentialed follow-up to an unapproved host
      # (station.md 8.2's rule, applied at the library seam; the
      # generated transport honors the fetchdef redirect slot).
      hosts =
        case is_map(profile_plugin) && profile_plugin["policy"] do
          %{"hosts" => hosts} when is_list(hosts) -> hosts
          _ -> nil
        end

      if nil != hosts and live do
        {_host, hostname, _path} = Station.parse_url(fullurl)

        if not Enum.member?(hosts, hostname) do
          err =
            Error.new(
              "station_host_allow",
              "egress to \"" <>
                hostname <> "\" denied by the hosts policy of plugin \"" <> slug <> "\""
            )

          Station.emit_err(station, slug, corr, err)
          throw({:station_ret, {nil, err}})
        end
      end

      senddef =
        if nil != hosts and live do
          d = S.clone(fetchdef)
          S.setprop(d, "redirect", "manual")
          d
        else
          fetchdef
        end

      # Injection: at the last boundary, below every recording feature,
      # and never into mock transports (station.md 3.3) - in test/mock
      # modes the placeholder rides through untouched, so real
      # credentials never enter in-memory mock stores. Copy-on-inject:
      # fetchdef.headers IS spec.headers and ctrl.explain holds the
      # fetchdef by reference, so the fetchdef (headers included) is
      # cloned before the swap - the object graph reachable from
      # ctx/spec/ctrl keeps the placeholder, ever (station.md 5.3).
      senddef =
        if live and nil != entry and "R1" == entry.rung do
          value =
            case Station.secret_value(station, slug) do
              {:ok, value} ->
                value

              {:error, err} ->
                Station.emit_err(station, slug, corr, err)
                throw({:station_ret, {nil, err}})
            end

          d = if senddef == fetchdef, do: S.clone(fetchdef), else: senddef
          headers = S.getprop(d, "headers")

          if S.ismap(headers) do
            Enum.each(S.keysof(headers), fn h ->
              v = S.getprop(headers, h)

              if is_binary(v) and String.contains?(v, placeholder) do
                S.setprop(headers, h, String.replace(v, placeholder, value))
              end
            end)
          end

          d
        else
          senddef
        end

      method = S.getprop(senddef, "method")
      started = Station.now_ms()

      {res, err} =
        try do
          inner.(fctx, fullurl, senddef)
        rescue
          e ->
            Station.emit_http(station, slug, corr, fullurl, method, 0, started, 0)
            Station.emit_err(station, slug, corr, e)
            reraise(e, __STACKTRACE__)
        end

      if nil != err do
        Station.emit_http(station, slug, corr, fullurl, method, 0, started, 0)
        Station.emit_err(station, slug, corr, err)
        {res, err}
      else
        status = int_of(if S.ismap(res), do: S.getprop(res, "status"), else: nil)
        Station.emit_http(station, slug, corr, fullurl, method, status, started, bytes_of(res))
        {res, err}
      end
    catch
      {:station_ret, ret} -> ret
    end
  end

  defp int_of(v) when is_integer(v), do: v
  defp int_of(v) when is_float(v), do: trunc(v)
  defp int_of(_), do: 0

  defp bytes_of(res) do
    headers = if S.ismap(res), do: S.getprop(res, "headers"), else: nil

    if S.ismap(headers) do
      cl =
        Enum.find_value(S.keysof(headers), fn k ->
          if "content-length" == String.downcase(to_string(k)), do: S.getprop(headers, k)
        end)

      case cl do
        nil ->
          0

        v ->
          case Integer.parse(to_string(v)) do
            {n, _} -> n
            :error -> 0
          end
      end
    else
      0
    end
  end

  defp corr_of(fctx) do
    stn = if S.ismap(fctx), do: S.getprop(fctx, "station$"), else: nil
    if S.ismap(stn), do: S.getprop(stn, "corr"), else: nil
  end

  # --- the hook bridge (design station.md 3 item 3) ---
  #
  # Operation semantics correlated with the HTTP events via a
  # per-operation id carried on the SDK's own ctx (the "station$" prop).
  # Hook dispatch ignores return values (the SDK contract), so hook/3
  # always returns nil.
  def hook(nil, _name, _ctx), do: nil

  def hook(%{station: station, slug: slug}, name, ctx) do
    case name do
      "PrePoint" ->
        S.setprop(
          ctx,
          "station$",
          S.jm(["corr", next_corr(), "start", Station.now_ms()])
        )

      "PreDone" ->
        op_event(station, slug, ctx, result_outcome(ctx))

      "PreUnexpected" ->
        op_event(station, slug, ctx, "unexpected")

      _ ->
        nil
    end

    nil
  end

  defp next_corr do
    "c" <> Integer.to_string(:erlang.unique_integer([:positive, :monotonic]))
  end

  def result_outcome(ctx) do
    result = S.getprop(ctx, "result")

    cond do
      nil == result -> "unknown"
      not S.ismap(result) -> "unknown"
      nil != S.getprop(result, "err") -> "err"
      false == S.getprop(result, "ok") -> "err"
      true -> "ok"
    end
  end

  defp op_event(station, slug, ctx, outcome) do
    stn = S.getprop(ctx, "station$")
    corr = if S.ismap(stn), do: S.getprop(stn, "corr"), else: nil
    start = if S.ismap(stn), do: S.getprop(stn, "start"), else: nil

    # ctx.op is the SDK's resolved Operation: name + entity, with "_" as
    # the generated Elixir SDKs' absence sentinel.
    op = S.getprop(ctx, "op")
    entity = sentinel(if(S.ismap(op), do: S.getprop(op, "entity"), else: nil))

    entity =
      if "" == entity do
        ent = S.getprop(ctx, "entity")
        sentinel(if(S.ismap(ent), do: S.getprop(ent, "_name"), else: nil))
      else
        entity
      end

    opname = sentinel(if(S.ismap(op), do: S.getprop(op, "name"), else: nil))

    Station.op_event(station, slug, corr, %{
      "entity" => entity,
      "op" => opname,
      "outcome" => outcome,
      "durationMs" => if(is_integer(start), do: Station.now_ms() - start, else: 0)
    })
  end

  defp sentinel(v), do: if(is_binary(v) and v != "_", do: v, else: "")

  # --- the carried adapter (design station.md 3.1 adopt) ---
  #
  # The retrofit path for SDKs generated without the station feature: a
  # struct feature node shaped exactly like the generated factory's
  # output (Feature.base + installed closures), added via options.extend.
  # It must stay behaviorally identical to the generated feature template
  # in sdkgen-station. See the module doc for why every closure is
  # installed HERE and captures this original node.
  def adapter_feature(station, calleropts) do
    f = S.jm([])
    S.setprop(f, "name", "station")
    S.setprop(f, "version", "0.0.1")
    S.setprop(f, "active", true)
    S.setprop(f, "options", S.jm([]))

    # feature_add reads _options for positioning: immediately after the
    # test feature's base transport (design station.md 3.3). When test is
    # absent from the add order this is a no-op append, which for a bare
    # SDK still lands the wrap immediately outside the base transport.
    S.setprop(f, "_options", S.jm(["__after__", "test"]))

    S.setprop(f, "init", fn ctx, fopts ->
      merged = if S.ismap(fopts), do: S.clone(fopts), else: S.jm([])
      S.setprop(merged, "station", fn -> station end)
      S.setprop(merged, "calleropts", calleropts)
      S.setprop(f, "_binding", feature_binding(ctx, merged))
      nil
    end)

    Enum.each(["PrePoint", "PreDone", "PreUnexpected"], fn name ->
      S.setprop(f, name, fn ctx ->
        hook(S.getprop(f, "_binding"), name, ctx)
        nil
      end)
    end)

    f
  end

  # --- plain <-> node conversion (the struct seam's edge) ---

  # Deep-convert a struct node into plain Elixir data (string-keyed maps,
  # lists, scalars) for the pure modules (descriptor normalization).
  # Non-node values (closures included) pass through.
  def plain(v) do
    cond do
      S.ismap(v) ->
        Map.new(S.keysof(v), fn k -> {k, plain(S.getprop(v, k))} end)

      S.islist(v) ->
        n = S.size(v)

        if n == 0 do
          []
        else
          Enum.map(0..(n - 1), fn i -> plain(S.getelem(v, i)) end)
        end

      true ->
        v
    end
  end

  # Deep-convert plain Elixir maps/lists into struct nodes; existing
  # nodes (and scalars/closures) pass through.
  def to_node(v) do
    cond do
      S.ismap(v) or S.islist(v) ->
        v

      is_map(v) and not is_struct(v) ->
        S.jm(Enum.flat_map(v, fn {k, x} -> [to_string(k), to_node(x)] end))

      is_list(v) ->
        S.jt(Enum.map(v, &to_node/1))

      true ->
        v
    end
  end
end
