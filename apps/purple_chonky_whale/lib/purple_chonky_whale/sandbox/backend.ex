defmodule PurpleChonkyWhale.Sandbox.Backend do
  @moduledoc """
  Behaviour for OS / container sandbox backends backing `PurpleChonkyWhale.Sandbox`.

  Backends transform a materialized `Executor.Runner.plan()` or an MCP
  `{:stdio, opts}` transport configuration to execute inside the backend's
  isolation boundary.
  """

  alias PurpleChonkyWhale.Executor.Runner
  alias PurpleChonkyWhale.Sandbox.Profile

  @callback available?(opts :: keyword()) :: :ok | {:error, String.t()}

  @callback wrap_plan(
              plan :: Runner.plan(),
              ctx :: map(),
              profile :: Profile.t(),
              opts :: keyword()
            ) :: {:ok, Runner.plan()} | {:error, String.t()}

  @callback wrap_stdio(
              stdio_opts :: keyword(),
              profile :: Profile.t(),
              opts :: keyword()
            ) :: {:ok, keyword()} | {:error, String.t()}
end
