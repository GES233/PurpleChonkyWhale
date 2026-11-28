defmodule Noctilucent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Noctilucent.Policy.Ast.Worker, Noctilucent.Policy.Ast.PowerShell.worker_opts()},
      {Noctilucent.Policy.Ast.Worker, Noctilucent.Policy.Ast.Python.worker_opts()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Noctilucent.Supervisor)
  end
end
