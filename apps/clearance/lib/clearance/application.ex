defmodule Clearance.Application do
  @moduledoc false

  # The AST analyzers for PowerShell and Python talk to a real parser over a
  # persistent Port. Their workers are lazy: no process is spawned and no
  # executable is located until the first parse, so starting them here costs
  # nothing for an application that never runs those runtimes. When the parser
  # is unavailable, `Clearance.Lint` falls back to regex plus `:ask`.
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Clearance.Lint.Ast.Worker, Clearance.Lint.Ast.PowerShell.worker_opts()},
      {Clearance.Lint.Ast.Worker, Clearance.Lint.Ast.Python.worker_opts()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Clearance.Supervisor)
  end
end
