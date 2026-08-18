# voxgig/station - Elixir port (hex package: voxgig_station).
#
# Zero dependencies (design station.md 10, the modem principle): the
# stdlib provides everything solo mode needs, and there is no Elixir
# sekreto port to depend on - secrets are env-only and the library says
# so (station.md 2.2). The struct seam (Voxgig.Struct) is resolved at
# runtime inside a generated SDK, never declared here.

defmodule Voxgig.Station.MixProject do
  use Mix.Project

  def project do
    [
      app: :voxgig_station,
      version: "0.0.1",
      elixir: "~> 1.14",
      description: "voxgig/station - one control surface for outbound integrations (solo mode)",
      start_permanent: Mix.env() == :prod,
      deps: [],
      package: package()
    ]
  end

  def application, do: [extra_applications: []]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Homepage" => "https://github.com/voxgig/station"}
    ]
  end
end
