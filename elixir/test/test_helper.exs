ExUnit.start()

# The carried adapter is built of Voxgig.Struct nodes, which a generated SDK
# supplies. A suite that drives it compiles the struct port from its sibling
# checkout, the way conform_test.exs compiles omni.
defmodule Voxgig.Station.TestStruct do
  def load do
    unless Code.ensure_loaded?(Voxgig.Struct) do
      Code.require_file(Path.join([home(), "elixir", "lib", "voxgig_struct.ex"]))
    end

    :ok
  end

  defp home do
    here = __DIR__

    candidates = [
      System.get_env("STRUCT_HOME"),
      Path.expand("../../../struct", here),
      Path.expand("../../../../struct", here),
      "/workspace/struct",
      "/home/user/struct"
    ]

    case Enum.find(candidates, fn c ->
           is_binary(c) and File.exists?(Path.join(c, "elixir/lib/voxgig_struct.ex"))
         end) do
      nil -> raise "station: voxgig/struct not found - set STRUCT_HOME"
      found -> Path.expand(found)
    end
  end
end
