# The secret broker (design station.md 5): a resolver names a secret,
# station places the value where the application cannot reach it. The
# broker holds resolved values privately - they never enter options,
# events, or captures; the SDK sees only the placeholder.
#
# A port of typescript/src/secrets.ts, which is canonical - with the one
# honest divergence the tier table (station.md 2.2) requires: **no Elixir
# sekreto port exists, so this library is env-only for secrets and says
# so.** It reads the process environment directly under the envtoken name
# - the one provider that needs no library - and refuses, rather than
# pretends, when a chain names any other store:
#
#   - an `env` provider that does not hold the name is a MISS and the
#     chain carries on (station_secret_no_value when every store missed);
#   - any non-env provider kind is a store this port CANNOT ANSWER from,
#     which per station.md 5.2 is an error (station_secret_error), never a
#     fall-through - skipping it would quietly reach for a weaker store.
#
# The permanent fix is a sekreto Elixir port, contributed to sekreto
# (station.md 18); until then, attached-mode proxy-side resolution is the
# path to vaults for Elixir apps, and this broker covers exactly solo.
#
# The two sekreto name rules this port needs are restated here EXACTLY
# once (sekreto typescript/src/Sekreto.ts validname/envkey - the corpus
# `secretname` section pins the round-trip): a name is dot-separated
# segments of [a-z0-9_]+, and its env key joins the segments with '_' and
# upper-cases.

defmodule Voxgig.Station.Secrets do
  alias Voxgig.Station.Error

  @namepart ~r/^[a-z0-9_]+$/

  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  def placeholder_for(slug), do: "[station:" <> to_string(slug || "") <> "]"

  # Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
  def encode_query_value(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # The placeholder becomes the value in header values and in the URL query,
  # where an SDK percent-encodes it (any hex case) and the value is encoded in
  # turn. The path and fragment are never touched. Returns {url, headers}.
  def substitute(url, headers, placeholder, value) do
    headers = if is_map(headers), do: headers, else: %{}

    if "" == placeholder do
      {url, headers}
    else
      {query_swap(url, placeholder, encode_query_value(value)),
       Map.new(headers, fn {name, v} ->
         {name, if(is_binary(v), do: String.replace(v, placeholder, value), else: v)}
       end)}
    end
  end

  defp query_swap(url, _placeholder, _encoded) when not is_binary(url), do: url

  defp query_swap(url, placeholder, encoded) do
    case String.split(url, "?", parts: 2) do
      [_] ->
        url

      [head, tail] ->
        {query, fragment} =
          case String.split(tail, "#", parts: 2) do
            [query] -> {query, ""}
            [query, fragment] -> {query, "#" <> fragment}
          end

        head <> "?" <> swap(query, placeholder, encoded, "") <> fragment
    end
  end

  defp swap("", _placeholder, _encoded, acc), do: acc

  defp swap(<<byte, rest::binary>> = query, placeholder, encoded, acc) do
    case match_at(query, placeholder) do
      {:ok, tail} -> swap(tail, placeholder, encoded, acc <> encoded)
      :nomatch -> swap(rest, placeholder, encoded, <<acc::binary, byte>>)
    end
  end

  # Each placeholder byte, literal or as %XX in either hex case.
  defp match_at(text, ""), do: {:ok, text}

  defp match_at(<<a, rest::binary>>, <<b, more::binary>>) when a == b,
    do: match_at(rest, more)

  defp match_at(<<?%, hi, lo, rest::binary>>, <<ch, more::binary>>)
       when is_hex(hi) and is_hex(lo) do
    if ch == String.to_integer(<<hi, lo>>, 16), do: match_at(rest, more), else: :nomatch
  end

  defp match_at(_text, _placeholder), do: :nomatch

  # sekreto's validname: dot-separated lowercase segments.
  def validname(name) do
    is_binary(name) and name != "" and
      name |> String.split(".") |> Enum.all?(&Regex.match?(@namepart, &1))
  end

  # sekreto's envkey: 'voxgig_solardemo.apikey' -> 'VOXGIG_SOLARDEMO_APIKEY'.
  def envkey(name, prefix \\ "") do
    prefix <> (to_string(name) |> String.split(".") |> Enum.join("_") |> String.upcase())
  end

  # -- broker state (held by the station instance's ETS slot) --
  #
  # overrides: values hoisted by adopt() from a resident options apikey
  # (design station.md 3.1); cache: one resolved value per plugin; held:
  # every value this broker ever held, for the exact-value scrub.

  def broker, do: %{overrides: %{}, cache: %{}, held: []}

  def hoist(broker, slug, value) do
    %{broker | overrides: Map.put(broker.overrides, slug, value), held: [value | broker.held]}
  end

  # Resolve the value for a plugin's secret name against the profile's
  # provider chain. Returns {:ok, value, broker'} | {:error, error} -
  # misses and store errors keep sekreto's distinction (design station.md
  # 5.2): a miss is station_secret_no_value, a store that could not answer
  # is station_secret_error, and never a retry against a weaker store.
  def value(broker, providers, slug, name) do
    cond do
      nil != broker.overrides[slug] ->
        {:ok, broker.overrides[slug], broker}

      nil != broker.cache[slug] ->
        {:ok, broker.cache[slug], broker}

      not validname(name) ->
        {:error,
         Error.new(
           "station_secret_error",
           "invalid secret name (sekreto name rules): " <> inspect(name)
         )}

      true ->
        case resolve_chain(chain(providers), name) do
          {:ok, value} ->
            {:ok, value,
             %{broker | cache: Map.put(broker.cache, slug, value), held: [value | broker.held]}}

          :miss ->
            {:error,
             Error.new(
               "station_secret_no_value",
               "no store had \"" <> name <> "\" for plugin \"" <> to_string(slug) <> "\""
             )}

          {:error, err} ->
            {:error, err}
        end
    end
  end

  defp chain(providers) when is_list(providers) and providers != [], do: providers
  defp chain(_), do: [%{"kind" => "env"}]

  defp resolve_chain([], _name), do: :miss

  defp resolve_chain([p | rest], name) do
    kind = if is_map(p), do: p["kind"], else: nil

    if "env" == kind do
      prefix = if is_binary(p["prefix"]), do: p["prefix"], else: ""

      case System.get_env(envkey(name, prefix)) do
        nil -> resolve_chain(rest, name)
        value -> {:ok, value}
      end
    else
      {:error,
       Error.new(
         "station_secret_error",
         "provider kind " <>
           inspect(kind) <>
           " is unavailable: no elixir sekreto port exists, so solo mode is " <>
           "env-only (station.md 2.2); the chain stops here rather than " <>
           "falling through to a weaker store (station.md 5.2)"
       )}
    end
  end

  # The provider kinds this env-only port cannot serve, for the says-so
  # warning at construction (design station.md 2.2).
  def unsupported_kinds(providers) do
    chain(providers)
    |> Enum.map(fn p -> if is_map(p), do: p["kind"], else: nil end)
    |> Enum.reject(&("env" == &1))
    |> Enum.map(&inspect/1)
    |> Enum.uniq()
  end

  # Exact-value scrub, deliberately WITHOUT sekreto's four-character
  # readability floor (design station.md 7 as revised): on boundaries
  # where the promise is absolute, every held value is scrubbed whatever
  # its length. There is no sekreto instance underneath this env-only
  # broker, so the held list is the complete set of values ever resolved
  # or hoisted - nothing more to delegate to.
  def scrub(broker, text) do
    text = if is_binary(text), do: text, else: to_string(text)

    Enum.reduce(broker.held, text, fn value, out ->
      if is_binary(value) and value != "" do
        out = String.replace(out, value, "[redacted]")
        encoded = encode_query_value(value)
        if encoded != value, do: String.replace(out, encoded, "[redacted]"), else: out
      else
        out
      end
    end)
  end

  # Drop the cache so the next resolve asks the stores again (rotation
  # support, design station.md 5.3). Hoisted overrides survive, as in the
  # canonical broker.
  def refresh(broker), do: %{broker | cache: %{}}
end
