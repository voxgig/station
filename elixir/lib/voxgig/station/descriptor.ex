# The descriptor is a VIEW over the embedded config every generated SDK
# carries, never a second model (design station.md 4). This module holds
# the identity grammar (envtoken/secretname), the normalizer (with the
# legacy-config sentinels), and the canonical serializer whose bytes every
# port must reproduce.
#
# A port of typescript/src/descriptor.ts, which is canonical. All values
# here are plain Elixir data - string-keyed maps, lists, scalars - the
# same shapes the conformance corpus speaks; nothing in this module knows
# about the SDKs' struct nodes (Voxgig.Station.Adapter converts).

defmodule Voxgig.Station.Descriptor do
  alias Voxgig.Station.Secrets

  # The ONLY way to build an env-var token in station, mirroring sdkgen's
  # packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
  # `secretname` corpus section pins the round-trip against sekreto's
  # envkey() and sdkgen's envName() - the one place three grammars meet.
  def envtoken(name) do
    to_string(name || "")
    |> String.upcase()
    |> then(&Regex.replace(~r/[^A-Z0-9]+/u, &1, "_"))
    |> then(&Regex.replace(~r/^_+|_+$/, &1, ""))
  end

  # The default sekreto name for a plugin (design station.md 5.1):
  # envtoken(slug) lowercased, plus '.apikey'. sekreto's envkey() then
  # yields exactly the env var the SDK's README documents:
  # gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
  def secretname_default(slug) do
    String.downcase(envtoken(slug)) <> ".apikey"
  end

  # Best-effort slug from a camel name, for SDKs whose embedded config
  # predates main.slug (design station.md 4 legacy sentinels). The hyphen
  # caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
  # 'voxgig-solardemo' - callers surface a warning event when this path is
  # taken.
  defp legacy_slug(name), do: String.downcase(to_string(name || ""))

  # Normalize a generated SDK's embedded config into descriptor v1
  # (design station.md 4). The config is the one every SDK carries
  # (Config main/feature/options/entity) as a plain string-keyed map; the
  # descriptor is a VIEW over it. Returns {descriptor, warnings}.
  def normalize(config, active_features \\ nil) do
    main = mmap(mget(config, "main"))
    options = mmap(mget(config, "options"))

    name = strv(main["name"])

    {slug, warnings} =
      case main["slug"] do
        s when is_binary(s) and s != "" ->
          {s, []}

        _ ->
          s = legacy_slug(name)

          {s,
           [
             "descriptor: legacy config has no main.slug; derived \"" <>
               s <> "\" from the camel name - hyphens in the original name are lost"
           ]}
      end

    version = if nil != main["version"], do: to_string(main["version"]), else: "0.0.0"
    target = if nil != main["target"], do: to_string(main["target"]), else: "unknown"

    svr = mmap(options["server"])

    server =
      svr
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()
      |> Enum.map(fn k -> %{"name" => k, "value" => to_string(svr[k])} end)

    auth_active = is_map(options["auth"])

    auth = %{
      "active" => auth_active,
      "prefix" => if(auth_active, do: strv(mget(options["auth"], "prefix")), else: ""),
      "secretname" => secretname_default(slug)
    }

    entities =
      mmap(mget(config, "entity"))
      |> Map.new(fn {ename, e} -> {to_string(ename), entity_view(mmap(e))} end)

    factive = mmap(active_features)

    features =
      mmap(mget(config, "feature"))
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()
      |> Enum.map(fn fname ->
        %{"name" => fname, "active" => true == mget(mmap(factive[fname]), "active")}
      end)

    descriptor = %{
      "station" => 1,
      "name" => name,
      "slug" => slug,
      "envtoken" => envtoken(slug),
      "version" => version,
      "target" => target,
      "base" => strv(options["base"]),
      "server" => server,
      "auth" => auth,
      "entities" => entities,
      "features" => features
    }

    {descriptor, warnings}
  end

  defp entity_view(e) do
    fields =
      listv(e["fields"])
      |> Enum.reduce(%{}, fn f, acc ->
        f = mmap(f)

        if nil != f["name"] do
          Map.put(acc, to_string(f["name"]), %{"kind" => strv(first_str(f["kind"], f["type"]))})
        else
          acc
        end
      end)

    opdefs = mmap(e["op"])

    ops =
      opdefs
      |> Map.new(fn {opname, op} ->
        points =
          listv(mget(mmap(op), "points"))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn p ->
            p = mmap(p)

            params =
              listv(p["parts"])
              |> Enum.filter(fn s -> is_binary(s) and String.starts_with?(s, ":") end)
              |> Enum.map(fn s -> String.slice(s, 1..-1//1) end)

            point = %{
              "method" => strv(p["method"]),
              "path" => strv(first_str(p["orig"], p["path"])),
              "params" => params
            }

            if nil != p["select"], do: Map.put(point, "select", p["select"]), else: point
          end)

        {to_string(opname), %{"points" => points}}
      end)

    %{"fields" => fields, "ops" => ops}
  end

  # Canonical serialization (design station.md 4): UTF-8, object keys
  # sorted bytewise, no insignificant whitespace, minimal JSON escaping.
  # The proxy dedupes registrations by a hash of this, so every language
  # must produce identical bytes - the `canonical-serialize` corpus
  # section carries the adversarial cases.
  #
  # Elixir binary comparison IS a bytewise comparison, so a plain sort of
  # the (string) keys gives the pinned order; numbers render JS-style -
  # an integral float prints without its fraction, exactly as the ts
  # reference's doubles do.
  def canonical_serialize(value) do
    cond do
      is_nil(value) ->
        "null"

      is_boolean(value) ->
        if value, do: "true", else: "false"

      is_number(value) ->
        js_number(value)

      is_binary(value) ->
        json_string(value)

      is_list(value) ->
        "[" <> Enum.map_join(value, ",", &canonical_serialize/1) <> "]"

      is_map(value) and not is_struct(value) ->
        keys = value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

        "{" <>
          Enum.map_join(keys, ",", fn k ->
            json_string(k) <> ":" <> canonical_serialize(mget(value, k))
          end) <> "}"

      # Elixir-side superset for opaque terms the wire never carries:
      # atoms render as their string, anything else as null (the ts
      # reference's fallthrough).
      is_atom(value) ->
        json_string(Atom.to_string(value))

      true ->
        "null"
    end
  end

  defp js_number(n) when is_integer(n), do: Integer.to_string(n)

  defp js_number(n) when is_float(n) do
    t = trunc(n)

    if t * 1.0 == n and abs(n) < 9.007199254740992e15 do
      Integer.to_string(t)
    else
      Float.to_string(n)
    end
  end

  defp json_string(s) do
    inner =
      for <<c::utf8 <- s>>, into: "" do
        case c do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          8 -> "\\b"
          12 -> "\\f"
          10 -> "\\n"
          13 -> "\\r"
          9 -> "\\t"
          c when c < 0x20 -> "\\u" <> hex4(c)
          _ -> <<c::utf8>>
        end
      end

    "\"" <> inner <> "\""
  end

  defp hex4(c) do
    c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end

  # -- small plain-data guards (nil-tolerant reads over untyped input) --

  defp mget(m, k) when is_map(m), do: Map.get(m, k)
  defp mget(_, _), do: nil

  defp mmap(v) when is_map(v) and not is_struct(v), do: v
  defp mmap(_), do: %{}

  defp listv(v) when is_list(v), do: v
  defp listv(_), do: []

  defp strv(v) when is_binary(v), do: v
  defp strv(_), do: ""

  defp first_str(a, b) do
    cond do
      is_binary(a) and a != "" -> a
      is_binary(b) and b != "" -> b
      true -> ""
    end
  end

  # Convenience: the sekreto env key of this plugin's default secret name
  # (used by remediation messages; the mapping itself lives in Secrets).
  def envkey(name, prefix \\ ""), do: Secrets.envkey(name, prefix)
end
