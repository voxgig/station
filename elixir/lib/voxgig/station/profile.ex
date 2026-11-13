# station.json lookup and profile resolution (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical. Config values
# are plain string-keyed maps (Voxgig.Station.Json's output, or whatever
# the caller passed to open/new as `config`).

defmodule Voxgig.Station.Profile do
  alias Voxgig.Station.Descriptor
  alias Voxgig.Station.Error
  alias Voxgig.Station.Json
  alias Voxgig.Station.Secrets

  # station.json lookup: cwd upward to the repo root, then
  # ~/.voxgig/station.json (design station.md 3.5). A repo root is where
  # .git lives; with no repo the walk stops at the filesystem root.
  def find_config_file(from \\ nil) do
    dir = Path.expand(from || File.cwd!())

    case find_up(dir) do
      nil ->
        home = System.user_home()

        if is_binary(home) and home != "" do
          candidate = Path.join([home, ".voxgig", "station.json"])
          if File.exists?(candidate), do: candidate, else: nil
        else
          nil
        end

      found ->
        found
    end
  end

  defp find_up(dir) do
    candidate = Path.join(dir, "station.json")

    cond do
      File.exists?(candidate) ->
        candidate

      File.exists?(Path.join(dir, ".git")) ->
        nil

      Path.dirname(dir) == dir ->
        nil

      true ->
        find_up(Path.dirname(dir))
    end
  end

  def load_config(from \\ nil) do
    case find_config_file(from) do
      nil ->
        nil

      file ->
        parse_config(File.read!(file), file)
    end
  end

  # A file that is not JSON is a config error, not a raw parser exception
  # escaping open(). Decoders disagree about an unpaired surrogate escape,
  # which I-JSON forbids, so the text is scanned before it is decoded.
  def parse_config(text, file \\ nil) do
    where = if nil == file, do: "station.json", else: "station.json at " <> file

    if not String.valid?(text) do
      Error.fail("station_config_invalid", where <> " is not UTF-8")
    end

    case unpaired_surrogate(text) do
      nil ->
        :ok

      literal ->
        Error.fail(
          "station_config_invalid",
          where <> " has an unpaired surrogate escape in " <> literal
        )
    end

    try do
      Json.parse(text)
    rescue
      err ->
        Error.fail(
          "station_config_invalid",
          where <> " is not valid JSON: " <> Exception.message(err)
        )
    end
  end

  # The first closed string literal, quotes included, holding a \u escape
  # for a surrogate that is not half of an escaped pair. Read by byte: no
  # byte of a multibyte character is a quote or a backslash.
  defp unpaired_surrogate(text), do: outside_string(text, text, 0)

  defp outside_string(text, <<?", rest::binary>>, at),
    do: inside_string(text, rest, at, at + 1, false)

  defp outside_string(text, <<_, rest::binary>>, at), do: outside_string(text, rest, at + 1)
  defp outside_string(_text, <<>>, _at), do: nil

  defp inside_string(text, <<?", rest::binary>>, start, at, unpaired) do
    if unpaired,
      do: binary_part(text, start, at + 1 - start),
      else: outside_string(text, rest, at + 1)
  end

  defp inside_string(text, <<?\\, _::binary>> = rest, start, at, unpaired) do
    unit = escaped_unit(rest)

    {skip, unpaired} =
      cond do
        high_surrogate?(unit) and low_surrogate?(escaped_unit(drop(rest, 6))) -> {12, unpaired}
        high_surrogate?(unit) or low_surrogate?(unit) -> {6, true}
        true -> {2, unpaired}
      end

    inside_string(text, drop(rest, skip), start, at + skip, unpaired)
  end

  defp inside_string(text, <<_, rest::binary>>, start, at, unpaired),
    do: inside_string(text, rest, start, at + 1, unpaired)

  defp inside_string(_text, <<>>, _start, _at, _unpaired), do: nil

  defp escaped_unit(<<?\\, ?u, hex::binary-size(4), _::binary>>) do
    if Enum.all?(:binary.bin_to_list(hex), &hex_digit?/1),
      do: String.to_integer(hex, 16),
      else: -1
  end

  defp escaped_unit(_), do: -1

  defp hex_digit?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp drop(bin, n) when byte_size(bin) <= n, do: <<>>
  defp drop(bin, n), do: binary_part(bin, n, byte_size(bin) - n)

  defp high_surrogate?(unit), do: unit in 0xD800..0xDBFF
  defp low_surrogate?(unit), do: unit in 0xDC00..0xDFFF

  # Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
  # else 'default' (design station.md 3.5 - env vars rank above
  # station.json but below open() opts; profile NAME selection follows the
  # same order with open() opts winning).
  def select(opt_profile \\ nil) do
    env = System.get_env("VOXGIG_STATION_PROFILE")

    cond do
      is_binary(opt_profile) and opt_profile != "" -> opt_profile
      is_binary(env) and env != "" -> env
      true -> "default"
    end
  end

  # Block defaults, applied AFTER the merge, never before (design 3.3,
  # 4.2). `active` is a real JSON boolean; `feature` is an empty map.
  # Elixir data is immutable, so sharing this literal per application is
  # safe (the mutable-language ports must allocate the feature map fresh
  # each time).
  @block_defaults %{"active" => true, "feature" => %{}}

  # The one block key carrying the timing rule: applied AFTER the merge,
  # never before (design 3.3, 4.2).
  @merge_sensitive ["active"]

  def block_defaults, do: @block_defaults

  def merge_sensitive, do: @merge_sensitive

  # The api half of a ref is the substring before the first `$`, and an
  # untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
  # point: under the old free-form identity which api an instance used
  # was itself a merged value, so a port that got the phasing wrong
  # silently picked another api's defaults.
  def refapi(ref) do
    ref |> to_string() |> String.split("$", parts: 2) |> hd()
  end

  # Shallow merge, per key, left to right - each source over the one
  # before it. An overlay's `policy` REPLACES the base's entirely rather
  # than merging `hosts` into it; an allowlist that widens because two
  # precedence levels merged is the failure this rule prevents.
  defp shallow(sources) do
    Enum.reduce(sources, %{}, fn src, acc ->
      if is_map(src) and not is_struct(src), do: Map.merge(acc, src), else: acc
    end)
  end

  # Sorted union of the (string) keys of the given maps; non-maps are
  # skipped. Elixir binary sort is bytewise, matching JS Array.sort.
  defp sortedkeys(maps) do
    maps
    |> Enum.filter(fn m -> is_map(m) and not is_struct(m) end)
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Merge the base profile ('default') with the selected overlay.
  #
  # Design 3.3's total order for the two block levels, lowest first:
  #
  #   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
  #
  # PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
  # LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
  # namespace, then put instance over api" - that lets every instance
  # value beat every api value, so a production `api.stripe.policy` would
  # fail to override a default profile's `sdk.stripe$test.policy`,
  # silently keeping the wider allowlist in production.
  #
  # `secrets.providers` replaces wholesale, never merges (3.5, 5.2 -
  # chain order decides which store wins, so a positional merge would be
  # actively dangerous). The `instance` corpus section pins all of this.
  def resolve(config, profile_name) do
    profiles = mmap(mget(config, "profiles"))
    base = mmap(profiles["default"])

    overlay =
      if "default" == profile_name, do: %{}, else: mmap(profiles[profile_name])

    providers =
      providers_of(overlay) || providers_of(base) || [%{"kind" => "env"}]

    base_api = mmap(base["api"])
    over_api = mmap(overlay["api"])
    base_sdk = mmap(base["sdk"])
    over_sdk = mmap(overlay["sdk"])

    # The api-level defaults in effect for this profile. A REPORT, not an
    # input to the instance merge below, and never defaulted.
    api =
      Enum.reduce(sortedkeys([base_api, over_api]), %{}, fn slug, acc ->
        Map.put(acc, slug, shallow([base_api[slug], over_api[slug]]))
      end)

    # An api block declares no instance of its own (3.1), so the ref set
    # comes from the two `sdk` maps alone.
    sdk =
      Enum.reduce(sortedkeys([base_sdk, over_sdk]), %{}, fn ref, acc ->
        a = refapi(ref)
        merged = shallow([base_api[a], base_sdk[ref], over_api[a], over_sdk[ref]])

        # Defaults are applied ONCE, to the fully merged instance, and
        # only where the key is ABSENT - an explicit false or {} must
        # survive. Had the overlay block carried a synthesized `active`
        # into the merge, a one-key environment override would silently
        # re-enable an integration the base declared inactive.
        merged =
          Enum.reduce(@block_defaults, merged, fn {k, v}, m ->
            if Map.has_key?(m, k), do: m, else: Map.put(m, k, v)
          end)

        Map.put(acc, ref, merged)
      end)

    checksecrets(sdk, profile_name)

    %{"name" => profile_name, "providers" => providers, "api" => api, "sdk" => sdk}
  end

  # A configured secret name sekreto would reject is caught at profile
  # load, not first request (14 station_secret_name) - and then the
  # DERIVED names are checked for uniqueness, because envtoken is lossy:
  # it collapses any run of non-alphanumerics to `_`, so `stripe$test`
  # and an untagged instance of a `stripe-test` api both derive
  # `stripe_test.apikey` and would silently share one credential.
  #
  # Two instances that EXPLICITLY name one secret are not a collision -
  # that is the shared-key case the api-level `secret` exists for.
  defp checksecrets(sdk, profile_name) do
    refs = sdk |> Map.keys() |> Enum.sort()

    Enum.each(refs, fn ref ->
      name = mget(sdk[ref], "secret")

      if nil != name and not Secrets.validname(name) do
        Error.fail(
          "station_secret_name",
          "profile \"" <>
            profile_name <>
            "\" sdk \"" <>
            ref <> "\": secret name rejected by sekreto: " <> inspect(name)
        )
      end
    end)

    Enum.reduce(refs, %{}, fn ref, seen ->
      written = mget(sdk[ref], "secret")
      derived = nil == written or "" == written
      name = if derived, do: Descriptor.secretname_default(ref), else: written

      case seen[name] do
        {prior_ref, prior_derived} when derived or prior_derived ->
          Error.fail(
            "station_secret_collision",
            "profile \"" <>
              profile_name <>
              "\": instances \"" <>
              prior_ref <>
              "\" and \"" <>
              ref <>
              "\" both resolve to secret name \"" <>
              to_string(name) <>
              "\", so they would share one credential; name it explicitly on " <>
              "each, or at the api level to share it deliberately (§5.1)"
          )

        nil ->
          Map.put(seen, name, {ref, derived})

        _prior ->
          seen
      end
    end)

    nil
  end

  # The block that governs an instance: its own, else its api's.
  def block_of(profile, ref) do
    case mget(mmap(mget(profile, "sdk")), ref) do
      nil -> mget(mmap(mget(profile, "api")), refapi(ref))
      block -> block
    end
  end

  # station.md 3.5 for a named instance: the block's `options`, then its
  # `base` (steps 3-6), under the caller's options (step 9), per
  # top-level key.
  def instance_options(block, opts) do
    out = mmap(mget(block, "options"))

    out =
      case mget(block, "base") do
        nil -> out
        base -> Map.put(out, "base", base)
      end

    Map.merge(out, mmap(opts))
  end

  defp providers_of(profile) do
    secrets = mmap(mget(profile, "secrets"))
    providers = secrets["providers"]
    if is_list(providers), do: providers, else: nil
  end

  defp mget(m, k) when is_map(m) and not is_struct(m), do: Map.get(m, k)
  defp mget(_, _), do: nil

  defp mmap(v) when is_map(v) and not is_struct(v), do: v
  defp mmap(_), do: %{}
end
