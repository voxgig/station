# station.json lookup and profile resolution (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical. Config values
# are plain string-keyed maps (Voxgig.Station.Json's output, or whatever
# the caller passed to open/new as `config`).

defmodule Voxgig.Station.Profile do
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
      nil -> nil
      file -> file |> File.read!() |> Json.parse()
    end
  end

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

  # Merge the base profile ('default') with the selected overlay:
  # deep-merge per plugin, EXCEPT secrets.providers which replaces
  # wholesale (design station.md 3.5, 5.2 - chain order decides which
  # store wins, so a positional merge would be actively dangerous). The
  # `profile` corpus section pins this.
  def resolve(config, profile_name) do
    profiles = mmap(mget(config, "profiles"))
    base = mmap(profiles["default"])

    overlay =
      if "default" == profile_name, do: %{}, else: mmap(profiles[profile_name])

    providers =
      providers_of(overlay) || providers_of(base) || [%{"kind" => "env"}]

    plugin =
      Enum.reduce([mmap(base["plugin"]), mmap(overlay["plugin"])], %{}, fn src, acc ->
        Enum.reduce(src, acc, fn {slug, popts}, acc2 ->
          if is_map(popts) do
            Map.put(acc2, slug, Map.merge(mmap(acc2[slug]), popts))
          else
            acc2
          end
        end)
      end)

    # A configured secret name sekreto would reject is caught at profile
    # load, not first request (design station.md 14 station_secret_name).
    plugin
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn slug ->
      name = mget(plugin[slug], "secret")

      if nil != name and not Secrets.validname(name) do
        Error.fail(
          "station_secret_name",
          "profile \"" <>
            profile_name <>
            "\" plugin \"" <>
            slug <> "\": secret name rejected by sekreto's name rules: " <> inspect(name)
        )
      end
    end)

    %{"name" => profile_name, "providers" => providers, "plugin" => plugin}
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
