defmodule Mix.Tasks.Noctilucent do
  @moduledoc "Start the Noctilucent personal agent REPL: `mix noctilucent -p tutor`"
  @shortdoc "Start the Noctilucent personal agent REPL"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Noctilucent.CLI.main(args)
  end
end
