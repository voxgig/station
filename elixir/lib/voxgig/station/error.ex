# Error codes follow the SDKs' house grammar (design station.md 14):
# <subject>_<condition>, absence as no_<thing>, gates as _allow.
# The `errors` corpus section pins the exact strings.
#
# A port of typescript/src/error.ts, which is canonical. The exception
# message is always "<code>: <msg>" so the code is greppable in any
# rendering of the error, and `code` rides as a struct field so the SDK
# error path (and duck-typed harnesses) can read it directly.

defmodule Voxgig.Station.Error do
  @codes [
    "station_no_proxy",
    "station_secret_no_value",
    "station_secret_error",
    "station_secret_name",
    "station_host_allow",
    "station_grant_expired",
    "station_wrap_order",
    "station_protocol",
    "station_no_plugin",
    "station_no_entity",
    "station_no_op",
    "station_agent_allow",
    "station_body_limit",
    "station_replay_lossy",
    "station_open_conflict",
    "station_bound_twice"
  ]

  defexception [:code, :msg]

  @impl true
  def exception(args) do
    %__MODULE__{
      code: Keyword.get(args, :code, ""),
      msg: Keyword.get(args, :msg, "")
    }
  end

  @impl true
  def message(%__MODULE__{code: code, msg: msg}) do
    to_string(code) <> ": " <> to_string(msg)
  end

  def new(code, msg), do: %__MODULE__{code: code, msg: msg}

  def fail(code, msg), do: raise(new(code, msg))

  def codes, do: @codes

  def known_code?(code), do: is_binary(code) and code in @codes
end
