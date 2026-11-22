defmodule DarkChonkyWhale.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: DarkChonkyWhale.AgentRunRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: DarkChonkyWhale.AgentRunSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DarkChonkyWhale.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
