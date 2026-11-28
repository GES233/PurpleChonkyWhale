defmodule Clearance.Component do
  @moduledoc """
  The `:policy` seam provider: starts one `Clearance.Policy` per composition
  and wires it onto the `:"tools/pre-execute"` waterfall.

  Config is exactly `Clearance.Policy`'s option list — see that module. A
  host that wants app-specific behaviour (extra linting, default protected
  directories, a different non-interactive policy) should mount its own thin
  component that builds the options and delegates, the way
  `Noctilucent.Policy` does.
  """

  use Dexterous.Component, provide: [:policy]

  alias Clearance.Policy
  alias Dexterous.Context

  @impl Dexterous.Component
  def apply(ctx, config) do
    {:ok, pid} = Policy.start_link(config)
    Process.unlink(pid)
    Context.track(ctx, pid)

    {:ok, _disposer} = Context.on(ctx, :"tools/pre-execute", Clearance.listener(pid))
    Context.set(ctx, :policy, pid)
  end
end
